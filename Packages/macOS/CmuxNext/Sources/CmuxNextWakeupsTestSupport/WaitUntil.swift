import Observation
public import Testing
import CmuxNextCompat

/// Waits until `condition` holds, woken by the observable state it reads, not by a poll.
///
/// Each check runs `condition` under `withObservationTracking`, so the `@Observable` properties it
/// reads are tracked; when one of them is about to change, the wait wakes and checks again on the
/// main actor. Nothing yields or sleeps in a loop, so a busy runner only makes the wait longer: it
/// never fails because a fixed number of turns ran out. State that is not observable does not wake
/// the wait; make a test double `@Observable` when a condition reads it.
///
/// The current test's time limit is the only bound. When the condition never holds (a regression),
/// the time limit cancels the test, the wait records an issue at the caller's line and ends with
/// `CancellationError`. In a test without a time limit it fails at once (``UnboundedWait``).
///
/// ```swift
/// @MainActor @Suite(.timeLimit(.minutes(1))) struct RequestsTests {
///     @Test func aRequestShowsItsCard() async throws {
///         let requests = AgentPermissionRequests(probe: probe, opener: opener)
///         let waiting = Task { await requests.request(request, timeout: .seconds(60)) }
///         try await waitUntil { requests.current != nil }
///     }
/// }
/// ```
///
/// - Parameters:
///   - condition: Reads main-actor state, at least one `@Observable` property of which changes on
///     the way to it holding.
///   - sourceLocation: Where the issue is recorded when the condition never held.
/// - Throws: ``UnboundedWait`` at once when the current test has no time limit; `CancellationError`
///   when the waiting task is cancelled before the condition held.
@MainActor
public func waitUntil(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try requireTimeLimit(for: "waitUntil(_:)")
    do {
        while true {
            try Task.checkCancellation()
            let change = ObservedChange()
            if withObservationTracking(condition, onChange: { change.happened() }) { return }
            try await change.wait()
        }
    } catch let error as CancellationError {
        Issue.record("the condition never held before the test was cancelled", sourceLocation: sourceLocation)
        throw error
    }
}

/// One `withObservationTracking` registration's change: it happens at most once, and the one
/// waiter wakes whether it parked before or after.
private final class ObservedChange: Sendable {
    private struct State {
        var happened = false
        var waiters = ParkedContinuations<Void>()
    }

    private let state = Mutex(State())

    /// The tracked state is about to change (`onChange`, called in the mutation's `willSet`).
    func happened() {
        let waiters = state.withLock { state in
            state.happened = true
            return state.waiters.takeAll()
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Waits until ``happened()`` ran, or returns at once when it ran already.
    func wait() async throws {
        let id = state.withLock { $0.waiters.newID() }
        try await parkUntilTaken { continuation in
            state.withLock { state in
                ParkDecision(resumeNow: state.waiters.park(id, continuation, arrived: state.happened))
            }
        } cancel: {
            state.withLock { $0.waiters.cancel(id) }
        }
    }
}
