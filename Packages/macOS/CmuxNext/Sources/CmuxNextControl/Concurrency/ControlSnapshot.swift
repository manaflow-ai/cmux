public import CmuxNextSettings
import Darwin
import Synchronization

/// An immutable picture of everything read-only control methods answer
/// from (plans/cmux-next/architecture.md section 5a).
///
/// The main actor builds it after each model settle and publishes it with
/// one atomic swap; connection tasks read it off the main actor. Fields are
/// value types with copy-on-write storage, so a read is a retain, not a
/// deep copy, and a reader never observes a half-applied update.
public struct ControlSnapshot: Sendable {
    /// Increments on every publish.
    public internal(set) var generation: UInt64 = 0
    /// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` at publish time.
    public internal(set) var publishedAtUptimeNanos: UInt64 = 0
    public var catalog: ControlCatalog = .empty
    public var topology = ControlTopology()
    /// The loaded cmux.json document, or nil before the first load.
    public var settings: JSONValue?

    public init() {}

    public static let empty = ControlSnapshot()

    /// True when the topology is loaded and reflects daemon events up to `sequence`.
    public func reflects(daemonSequence sequence: UInt64) -> Bool {
        topology.isLoaded && topology.daemonSequence >= sequence
    }
}

/// The atomic reference that publishes ``ControlSnapshot``s. Writers are
/// the main actor (topology, settings) and the registry bridge (catalog);
/// readers are connection tasks. The lock is held only for a struct copy.
///
/// Readers that must observe a write wait with
/// ``snapshot(reflecting:deadline:)``: a publish that passes their daemon
/// sequence resumes them; a deadline bounds the wait.
public final class ControlSnapshotStore: Sendable {
    private struct Waiter {
        let id: UInt64
        let sequence: UInt64
        let continuation: CheckedContinuation<ControlSnapshot?, Never>
    }

    private struct State {
        var snapshot = ControlSnapshot()
        var waiters: [Waiter] = []
        var nextWaiter: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// The latest published snapshot.
    public var current: ControlSnapshot { state.withLock { $0.snapshot } }

    /// True while a reader waits for a newer topology; the publisher then
    /// publishes on the next main-actor turn instead of the next frame.
    public var hasWaiters: Bool { state.withLock { !$0.waiters.isEmpty } }

    /// Applies `update` to a copy of the current snapshot and publishes the
    /// result. Build expensive values before calling: the lock is held for
    /// the closure's duration.
    @discardableResult
    public func publish(_ update: (inout ControlSnapshot) -> Void) -> UInt64 {
        let (generation, snapshot, ready) = state.withLock { state -> (UInt64, ControlSnapshot, [Waiter]) in
            update(&state.snapshot)
            state.snapshot.generation &+= 1
            state.snapshot.publishedAtUptimeNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard !state.waiters.isEmpty else { return (state.snapshot.generation, state.snapshot, []) }
            let snapshot = state.snapshot
            let ready = state.waiters.filter { snapshot.reflects(daemonSequence: $0.sequence) }
            if !ready.isEmpty { state.waiters.removeAll { snapshot.reflects(daemonSequence: $0.sequence) } }
            return (snapshot.generation, snapshot, ready)
        }
        for waiter in ready { waiter.continuation.resume(returning: snapshot) }
        return generation
    }

    /// The first published snapshot whose topology reflects daemon events up
    /// to `sequence` (the current one when it already does), or nil at
    /// `deadline` or on cancellation. Never blocks a thread.
    public func snapshot(reflecting sequence: UInt64, deadline: ContinuousClock.Instant) async -> ControlSnapshot? {
        let (ready, id) = state.withLock { state -> (ControlSnapshot?, UInt64) in
            if state.snapshot.reflects(daemonSequence: sequence) { return (state.snapshot, 0) }
            state.nextWaiter &+= 1
            return (nil, state.nextWaiter)
        }
        if let ready { return ready }
        let timer = Task { [weak self] in
            // wakeup-allow: one-shot read-barrier deadline (1 s), cancelled when the store catches up
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.resolve(id, with: nil)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Resume now when already satisfied or cancelled (the
                // cancellation handler may have run before this waiter existed).
                let now = state.withLock { state -> ControlSnapshot?? in
                    if state.snapshot.reflects(daemonSequence: sequence) { return .some(state.snapshot) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters.append(Waiter(id: id, sequence: sequence, continuation: continuation))
                    return .none
                }
                if case .some(let result) = now { continuation.resume(returning: result) }
            }
        } onCancel: {
            resolve(id, with: nil)
        }
    }

    private func resolve(_ id: UInt64, with snapshot: ControlSnapshot?) {
        let waiter = state.withLock { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return state.waiters.remove(at: index)
        }
        waiter?.continuation.resume(returning: snapshot)
    }
}
