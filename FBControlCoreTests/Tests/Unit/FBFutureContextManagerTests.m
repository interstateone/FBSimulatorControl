/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <XCTest/XCTest.h>

#import <FBControlCore/FBControlCore.h>

@interface FBFutureContextManagerTests : XCTestCase <FBFutureContextManagerDelegate>

@property (nonatomic, strong, readwrite) dispatch_queue_t queue;
@property (nonatomic, assign, readwrite) NSUInteger prepareCalled;
@property (nonatomic, assign, readwrite) NSUInteger teardownCalled;
@property (nonatomic, copy, readwrite) NSNumber *contextPoolTimeout;

@end

@implementation FBFutureContextManagerTests

- (void)setUp
{
  self.queue = dispatch_queue_create("com.facebook.fbcontrolcore.tests.future_context", DISPATCH_QUEUE_SERIAL);
  self.contextPoolTimeout = nil;
  self.prepareCalled = 0;
  self.teardownCalled = 0;
}

- (FBFutureContextManager<NSNumber *> *)manager
{
  id<FBControlCoreLogger> logger = [FBControlCoreGlobalConfiguration.defaultLogger withName:@"manager_test"];
  return [FBFutureContextManager managerWithQueue:self.queue delegate:self logger:logger];
}

- (void)testSingleAquire
{
  FBFuture *future = [[self.manager
    utilizeWithPurpose:@"A Test"]
    onQueue:self.queue fmap:^(id result) {
      return [FBFuture futureWithResult:@123];
    }];

  NSError *error = nil;
  id value = [future awaitWithTimeout:1 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(value, @123);

  XCTAssertEqual(self.prepareCalled, 1u);
  XCTAssertEqual(self.teardownCalled, 1u);
}

- (void)testSequentialAquire
{
  FBFutureContextManager<NSNumber *> *manager = self.manager;

  FBFuture *future0 = [[manager
    utilizeWithPurpose:@"A Test"]
    onQueue:self.queue fmap:^(id result) {
      return [FBFuture futureWithResult:@0];
    }];

  NSError *error = nil;
  id value = [future0 awaitWithTimeout:1 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(value, @0);

  XCTAssertEqual(self.prepareCalled, 1u);
  XCTAssertEqual(self.teardownCalled, 1u);

  FBFuture *future1 = [[manager
    utilizeWithPurpose:@"A Test"]
    onQueue:self.queue fmap:^(id result) {
      return [FBFuture futureWithResult:@1];
    }];
  value = [future1 awaitWithTimeout:1 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(value, @1);

  XCTAssertEqual(self.prepareCalled, 2u);
  XCTAssertEqual(self.teardownCalled, 2u);
}

- (void)testSequentialAquireWithCooloff
{
  FBFutureContextManager<NSNumber *> *manager = self.manager;
  self.contextPoolTimeout = @0.2;

  FBFuture *future0 = [[manager
    utilizeWithPurpose:@"A Test"]
    onQueue:self.queue fmap:^(id result) {
      return [FBFuture futureWithResult:@0];
    }];

  NSError *error = nil;
  id value = [future0 awaitWithTimeout:1 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(value, @0);

  XCTAssertEqual(self.prepareCalled, 1u);
  XCTAssertEqual(self.teardownCalled, 0u);

  FBFuture *future1 = [[manager
    utilizeWithPurpose:@"A Test"]
    onQueue:self.queue fmap:^(id result) {
      return [FBFuture futureWithResult:@1];
    }];
  value = [future1 awaitWithTimeout:1 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(value, @1);

  XCTAssertEqual(self.prepareCalled, 1u);
  XCTAssertEqual(self.teardownCalled, 0u);

  [[FBFuture futureWithDelay:0.25 future:[FBFuture futureWithResult:NSNull.null]] await:nil];

  XCTAssertEqual(self.prepareCalled, 1u);
  XCTAssertEqual(self.teardownCalled, 1u);
}

- (void)testConcurrentAquireOnlyPreparesOnce
{
  FBFutureContextManager<NSNumber *> *manager = self.manager;
  dispatch_queue_t concurrent = dispatch_queue_create("com.facebook.fbcontrolcore.tests.future_context.concurrent", DISPATCH_QUEUE_CONCURRENT);
  FBMutableFuture *future0 = FBMutableFuture.future;
  FBMutableFuture *future1 = FBMutableFuture.future;
  FBMutableFuture *future2 = FBMutableFuture.future;

  dispatch_async(concurrent, ^{
    FBFuture *inner = [[manager
      utilizeWithPurpose:@"A Test"]
      onQueue:self.queue fmap:^(id result) {
        return [FBFuture futureWithResult:@0];
      }];
    [future0 resolveFromFuture:inner];
  });
  dispatch_async(concurrent, ^{
    FBFuture *inner = [[manager
      utilizeWithPurpose:@"A Test"]
      onQueue:self.queue fmap:^(id result) {
        return [FBFuture futureWithResult:@1];
      }];
    [future1 resolveFromFuture:inner];
  });
  dispatch_async(concurrent, ^{
    FBFuture *inner = [[manager
      utilizeWithPurpose:@"A Test"]
      onQueue:self.queue fmap:^(id result) {
        return [FBFuture futureWithResult:@2];
      }];
    [future2 resolveFromFuture:inner];
  });

  NSError *error = nil;
  id value = [[FBFuture futureWithFutures:@[future0, future1, future2]] awaitWithTimeout:1 error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(value, (@[@0, @1, @2]));

  XCTAssertEqual(self.prepareCalled, 1u);
  XCTAssertEqual(self.teardownCalled, 1u);
}

- (void)testImmediateAquireAndRelease
{
  FBFutureContextManager<NSNumber *> *manager = self.manager;

  NSError *error = nil;
  NSNumber *context = [manager utilizeNowWithPurpose:@"A Test" error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(context, @0);

  BOOL success = [manager returnNowWithPurpose:@"A Test" error:&error];
  XCTAssertNil(error);
  XCTAssertTrue(success);
}

- (NSString *)contextName
{
  return @"A Test";
}

- (FBFuture<id> *)prepare:(id<FBControlCoreLogger>)logger
{
  self.prepareCalled++;
  return [FBFuture futureWithResult:@0];
}

- (FBFuture<NSNull *> *)teardown:(id)context logger:(id<FBControlCoreLogger>)logger
{
  self.teardownCalled++;
  return [FBFuture futureWithResult:NSNull.null];
}

@end
