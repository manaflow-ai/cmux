import Foundation
import Testing
import UserNotifications
import os
@testable import CmuxNotifications

/// A controllable stand-in for the framework's callback surface.
///
/// The optional entry semaphore models the framework's synchronous XPC wait on
/// a wedged `usernotificationsd`: the call blocks at method entry, before any
/// completion handler is wired up. The semaphore is deliberate here — blocking
/// a thread is the exact behavior under test.
private final class StubCallingCenter: UserNotificationCenterCalling, @unchecked Sendable {
    var delegate: (any UNUserNotificationCenterDelegate)?

    private struct State {
        var startedAdds = 0
        var finishedAdds = 0
        var startedRemovals = 0
    }

    // Safety: the lock guards simple counters written from the service's
    // worker queue and read from the test.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let addEntryWedge: DispatchSemaphore?
    private let addCompletionError: (any Error)?
    private let addCompletes: Bool
    private let authorizationGrant: (Bool, (any Error)?)?

    /// Invoked as soon as an `add` enters the (possibly wedged) framework call.
    var onAddStarted: (@Sendable () -> Void)?

    init(
        addEntryWedge: DispatchSemaphore? = nil,
        addCompletionError: (any Error)? = nil,
        addCompletes: Bool = true,
        authorizationGrant: (Bool, (any Error)?)? = nil
    ) {
        self.addEntryWedge = addEntryWedge
        self.addCompletionError = addCompletionError
        self.addCompletes = addCompletes
        self.authorizationGrant = authorizationGrant
    }

    var startedAdds: Int {
        state.withLock { $0.startedAdds }
    }

    var finishedAdds: Int {
        state.withLock { $0.finishedAdds }
    }

    var startedRemovals: Int {
        state.withLock { $0.startedRemovals }
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}

    func getNotificationCategories(
        completionHandler: @escaping @Sendable (Set<UNNotificationCategory>) -> Void
    ) {
        completionHandler([])
    }

    func getNotificationSettings(
        completionHandler: @escaping @Sendable (UNNotificationSettings) -> Void
    ) {
        // `UNNotificationSettings` has no public initializer; the settings
        // path is exercised through its timeout behavior only.
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        guard let authorizationGrant else { return }
        completionHandler(authorizationGrant.0, authorizationGrant.1)
    }

    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?
    ) {
        state.withLock { $0.startedAdds += 1 }
        onAddStarted?()
        addEntryWedge?.wait()
        state.withLock { $0.finishedAdds += 1 }
        guard addCompletes else { return }
        completionHandler?(addCompletionError)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        state.withLock { $0.startedRemovals += 1 }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        state.withLock { $0.startedRemovals += 1 }
    }
}

/// Fires the service deadline only when the test asks for it, so timeout
/// behavior is asserted causally instead of against real elapsed time.
private final class ManualDeadline: @unchecked Sendable {
    private struct State {
        var fired = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    // Safety: the lock performs a short compare-and-set around continuation
    // settlement; waiters installed after `fire()` resume immediately.
    private let state = OSAllocatedUnfairLock(initialState: State())

    var sleep: UserNotificationCenterService.Sleep {
        { [self] _ in
            await withCheckedContinuation { continuation in
                let alreadyFired = state.withLock { state -> Bool in
                    if state.fired { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if alreadyFired {
                    continuation.resume()
                }
            }
        }
    }

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// A one-shot signal that tolerates signal-before-wait ordering.
private final class AsyncFlag: @unchecked Sendable {
    private struct State {
        var signaled = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    // Safety: the lock performs a short compare-and-set around one
    // continuation settlement.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func signal() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.signaled = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadySignaled = state.withLock { state -> Bool in
                if state.signaled { return true }
                state.waiter = continuation
                return false
            }
            if alreadySignaled {
                continuation.resume()
            }
        }
    }
}

struct UserNotificationCenterServiceTests {
    private static func makeService(
        center: StubCallingCenter,
        queue: DispatchQueue,
        deadline: ManualDeadline? = nil
    ) -> UserNotificationCenterService {
        let sleep: UserNotificationCenterService.Sleep
        if let deadline {
            sleep = deadline.sleep
        } else {
            // Success-path tests: a deadline that never fires on its own. The
            // call gate cancels this task once the real completion lands,
            // which throws out of the sleep.
            sleep = { _ in
                try await Task.sleep(for: .seconds(600))
            }
        }
        return UserNotificationCenterService(
            center: center,
            operationQueue: queue,
            timeout: .seconds(2),
            sleep: sleep
        )
    }

    private static func makeRequest(identifier: String = "test") -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: identifier,
            content: UNMutableNotificationContent(),
            trigger: nil
        )
    }

    private static func isTimedOut(_ result: Result<Void, UserNotificationCenterFailure>) -> Bool {
        if case .failure(.timedOut) = result { return true }
        return false
    }

    private static func isSuccess(_ result: Result<Void, UserNotificationCenterFailure>) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    @Test("a call whose completion never arrives resolves as a timeout at the deadline")
    func neverCompletingCallTimesOut() async {
        let deadline = ManualDeadline()
        let entered = AsyncFlag()
        let center = StubCallingCenter(addCompletes: false)
        center.onAddStarted = { entered.signal() }
        let queue = DispatchQueue(label: "test.un-service.never-completes")
        let service = Self.makeService(center: center, queue: queue, deadline: deadline)

        async let pending = service.add(Self.makeRequest())
        await entered.wait()
        deadline.fire()
        let result = await pending

        #expect(Self.isTimedOut(result))
        #expect(center.startedAdds == 1)
    }

    @Test("a synchronously wedged framework entry resolves the awaiting caller while still blocked")
    func wedgedEntryTimesOutWithoutBlockingCaller() async {
        let wedge = DispatchSemaphore(value: 0)
        defer { wedge.signal() }
        let deadline = ManualDeadline()
        let entered = AsyncFlag()
        let center = StubCallingCenter(addEntryWedge: wedge)
        center.onAddStarted = { entered.signal() }
        let queue = DispatchQueue(label: "test.un-service.wedged-entry")
        let service = Self.makeService(center: center, queue: queue, deadline: deadline)

        async let pending = service.add(Self.makeRequest())
        await entered.wait()
        deadline.fire()
        let result = await pending

        #expect(Self.isTimedOut(result))
        // Causal proof the caller resolved while the framework entry was
        // still blocked: the wedge is only released by the deferred signal.
        #expect(center.finishedAdds == 0)
    }

    @Test("a call queued behind a wedged call times out and its framework entry never starts")
    func queuedCallBehindWedgeNeverStarts() async {
        let wedge = DispatchSemaphore(value: 0)
        let deadline = ManualDeadline()
        let entered = AsyncFlag()
        let center = StubCallingCenter(addEntryWedge: wedge)
        center.onAddStarted = { entered.signal() }
        let queue = DispatchQueue(label: "test.un-service.queued-behind-wedge")
        let service = Self.makeService(center: center, queue: queue, deadline: deadline)

        async let first = service.add(Self.makeRequest(identifier: "first"))
        async let second = service.add(Self.makeRequest(identifier: "second"))
        await entered.wait()
        deadline.fire()
        let results = await [first, second]

        #expect(results.allSatisfy(Self.isTimedOut))
        wedge.signal()
        await Self.drain(queue)
        #expect(center.startedAdds == 1)
    }

    @Test("a completing add passes success and system errors through")
    func addPassesThroughCompletion() async {
        let queue = DispatchQueue(label: "test.un-service.add-completes")
        let succeeding = Self.makeService(center: StubCallingCenter(), queue: queue)
        #expect(Self.isSuccess(await succeeding.add(Self.makeRequest())))

        let failure = NSError(domain: "cmuxTests.UNService", code: 7)
        let failing = Self.makeService(
            center: StubCallingCenter(addCompletionError: failure),
            queue: queue
        )
        let result = await failing.add(Self.makeRequest())
        guard case .failure(.system(let message)) = result else {
            Issue.record("expected a system failure, got \(result)")
            return
        }
        #expect(message == failure.localizedDescription)
    }

    @Test("requestAuthorization maps the framework grant and times out when unresponsive")
    func requestAuthorizationMapsGrant() async {
        let queue = DispatchQueue(label: "test.un-service.authorization")
        let granting = Self.makeService(
            center: StubCallingCenter(authorizationGrant: (true, nil)),
            queue: queue
        )
        #expect(await granting.requestAuthorization(options: [.alert, .sound]) == .success(true))

        let deadline = ManualDeadline()
        let unresponsive = Self.makeService(
            center: StubCallingCenter(),
            queue: queue,
            deadline: deadline
        )
        deadline.fire()
        let result = await unresponsive.requestAuthorization(options: [.alert, .sound])
        #expect(result == .failure(.timedOut))
    }

    @Test("settings lookups against an unresponsive center resolve as a timeout at the deadline")
    func authorizationStatusTimesOut() async {
        let deadline = ManualDeadline()
        let queue = DispatchQueue(label: "test.un-service.settings")
        let service = Self.makeService(
            center: StubCallingCenter(),
            queue: queue,
            deadline: deadline
        )

        deadline.fire()
        let result = await service.authorizationStatus()

        #expect(result == .failure(.timedOut))
    }

    @Test("removals with no identifiers succeed without entering the framework")
    func emptyRemovalsShortCircuit() async {
        let center = StubCallingCenter()
        let queue = DispatchQueue(label: "test.un-service.empty-removals")
        let service = Self.makeService(center: center, queue: queue)

        #expect(Self.isSuccess(await service.removeDeliveredNotifications(withIdentifiers: [])))
        #expect(Self.isSuccess(await service.removePendingNotificationRequests(withIdentifiers: [])))
        await Self.drain(queue)
        #expect(center.startedRemovals == 0)
    }

    @Test("removals pass through the bounded boundary")
    func removalsRunOnWorkerQueue() async {
        let center = StubCallingCenter()
        let queue = DispatchQueue(label: "test.un-service.removals")
        let service = Self.makeService(center: center, queue: queue)

        #expect(Self.isSuccess(await service.removeDeliveredNotifications(withIdentifiers: ["a"])))
        #expect(Self.isSuccess(await service.removePendingNotificationRequests(withIdentifiers: ["b"])))
        #expect(center.startedRemovals == 2)
    }
}
