public import Testing
import Darwin
import Foundation
import os

/// A process-wide bound on how many heavy tests (a live app on a daemon, real windows) run at
/// once, whatever Swift Testing's parallelization width is.
///
/// Swift Testing's width (`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`) bounds every test case
/// alike. A heavy app fixture keeps the main actor busy for seconds, so a width that suits the
/// thousands of small tests can still put more app fixtures on the one main actor than it can
/// serve before their deadlines. The shared fixtures (`PinnedPageTests.withApp`,
/// `PasswordManagerRouteTests.withApp` and the others in CmuxNextAppTests) run their body under
/// ``withPermit(isolation:_:)`` of ``shared``; a suite that has no shared fixture can take the
/// ``Trait/takesATestPermit`` trait.
///
/// - Fair: permits go to waiters in the order they asked (FIFO); a new caller never takes a
///   permit ahead of one that waits.
/// - Cancellation-safe: a waiter whose task is cancelled leaves the queue and throws
///   `CancellationError`; it never holds a permit.
/// - Re-entrant: a task that holds a permit of this limiter (and its child tasks, through a task
///   local) runs a nested ``withPermit(isolation:_:)`` without taking a second one, so a fixture
///   that calls another fixture cannot wait on itself.
public nonisolated final class TestPermits: Sendable {
    /// The limiter the shared fixtures use: `CMUX_TEST_PERMITS` permits when that is a positive
    /// number, else the physical core count.
    public static let shared = TestPermits(limit: TestPermits.configuredLimit(ProcessInfo.processInfo.environment), name: "shared")

    /// How many permits exist.
    public let limit: Int
    /// Names the limiter in the stderr line it writes at each new peak; nil writes nothing.
    let name: String?

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var available: Int
        var waiters: [Waiter] = []
        var nextID: UInt64 = 0
        var peakInUse = 0
        var peakWaiting = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    /// The limiters the current task holds a permit of (inherited by its child tasks).
    @TaskLocal static var held: Set<ObjectIdentifier> = []

    public init(limit: Int, name: String? = nil) {
        precondition(limit > 0, "TestPermits needs at least one permit")
        self.limit = limit
        self.name = name
        state = OSAllocatedUnfairLock(initialState: State(available: limit))
    }

    /// `CMUX_TEST_PERMITS` from `environment` when it is a positive number, else the physical core count.
    public static func configuredLimit(_ environment: [String: String]) -> Int {
        if let value = environment["CMUX_TEST_PERMITS"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), value > 0 {
            return value
        }
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Whether the current task already holds a permit of this limiter.
    public var isHeldByCurrentTask: Bool { Self.held.contains(ObjectIdentifier(self)) }

    /// Permits handed out now, and callers waiting for one.
    public var usage: (inUse: Int, waiting: Int) {
        state.withLock { (limit - $0.available, $0.waiters.count) }
    }

    /// The most permits in use at once and the most callers waiting at once, since launch.
    public var peaks: (inUse: Int, waiting: Int) {
        state.withLock { ($0.peakInUse, $0.peakWaiting) }
    }

    /// Runs `body` while holding one permit: waits in line for it unless the current task holds one
    /// already. Throws `CancellationError`, and does not run `body`, when the task is cancelled
    /// while it waits.
    public func withPermit<R>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async throws -> R {
        let key = ObjectIdentifier(self)
        if Self.held.contains(key) { return try await body() }
        try await acquire()
        defer { release() }
        return try await Self.$held.withValue(Self.held.union([key]), operation: { try await body() }, isolation: isolation)
    }

    /// Takes one permit, waiting behind earlier callers. The caller must ``release()`` it.
    /// Prefer ``withPermit(isolation:_:)``, which releases on every path and is re-entrant.
    public func acquire() async throws {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Under the lock: the cancellation handler below takes it too, and the task is
                // marked cancelled before that handler runs. So either this check sees the
                // cancellation, or the handler runs after this waiter is queued and removes it.
                let (outcome, peak) = state.withLock { state -> (Result<Void, any Error>?, String?) in
                    if Task.isCancelled { return (.failure(CancellationError()), nil) }
                    if state.available > 0, state.waiters.isEmpty {
                        state.available -= 1
                        let inUse = limit - state.available
                        guard inUse > state.peakInUse else { return (.success(()), nil) }
                        state.peakInUse = inUse
                        return (.success(()), "\(inUse) of \(limit) in use")
                    }
                    state.waiters.append(Waiter(id: id, continuation: continuation))
                    let waiting = state.waiters.count
                    guard waiting > state.peakWaiting else { return (nil, nil) }
                    state.peakWaiting = waiting
                    // Powers of two only: a long queue writes a few lines, not one per waiter.
                    return (nil, waiting & (waiting - 1) == 0 ? "all \(limit) in use, \(waiting) waiting" : nil)
                }
                if let peak { report(peak) }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let removed = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            removed?.continuation.resume(throwing: CancellationError())
        }
    }

    /// One stderr line per new peak, so a test log shows whether the limiter ever made a test wait.
    private func report(_ peak: String) {
        guard let name else { return }
        let line = Array("cmux-test permits (\(name)): new peak, \(peak)\n".utf8)
        _ = line.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }

    /// Gives back one permit: the longest waiter takes it, or it becomes free.
    public func release() {
        let next = state.withLock { state -> Waiter? in
            if state.waiters.isEmpty {
                precondition(state.available < limit, "TestPermits released more permits than it handed out")
                state.available += 1
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.continuation.resume()
    }
}

/// The trait form of ``TestPermits/shared``: each test case of the suite or test runs under one
/// permit (re-entrant with the shared fixtures, which take the same limiter).
public nonisolated struct TestPermitScope: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    @concurrent public nonisolated func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        // A suite's own scope holds nothing: its tests take their permits one by one, so a suite
        // never holds a permit while its tests wait for theirs.
        guard testCase != nil else { return try await function() }
        try await TestPermits.shared.withPermit(isolation: nil) { try await function() }
    }
}

extension Trait where Self == TestPermitScope {
    /// Each test case runs under a permit of ``TestPermits/shared`` (``TestPermitScope``).
    public nonisolated static var takesATestPermit: Self { TestPermitScope() }
}
