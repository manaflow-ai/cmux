public import CmuxNextSettings
import Darwin
import CmuxNextCompat

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
    /// Recency, closing and closed tabs for `tabs.search`.
    public var tabSearch = ControlTabSearchFacts()

    public init() {}

    public static let empty = ControlSnapshot()

    /// True when the topology is loaded and reflects home daemon events up to `sequence`.
    public func reflects(daemonSequence sequence: UInt64) -> Bool {
        reflects(ControlSequenceBarrier(home: sequence))
    }

    /// True when the topology is loaded and reflects every session's daemon
    /// events up to its sequence in `barrier`. A session the topology no
    /// longer reports (disconnected, forgotten) cannot be waited for.
    public func reflects(_ barrier: ControlSequenceBarrier) -> Bool {
        guard topology.isLoaded, topology.daemonSequence >= barrier.home else { return false }
        return barrier.sessions.allSatisfy { id, sequence in
            guard let applied = topology.sessionSequences[id] else { return topology.session(id: id) == nil }
            return applied >= sequence
        }
    }
}

/// Daemon event sequences a read must see (read-your-writes across
/// sessions): the home daemon's, and each remote session's by
/// `ControlSessionInfo.id`. Sequences are per daemon connection.
public struct ControlSequenceBarrier: Sendable, Hashable {
    public var home: UInt64
    public var sessions: [String: UInt64]

    public init(home: UInt64 = 0, sessions: [String: UInt64] = [:]) {
        self.home = home
        self.sessions = sessions
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
        let isReady: @Sendable (ControlSnapshot) -> Bool
        let continuation: CheckedContinuation<ControlSnapshot?, Never>
    }

    private struct State {
        var snapshot = ControlSnapshot()
        var waiters: [Waiter] = []
        var nextWaiter: UInt64 = 0
    }

    private let state = Mutex(State())
    /// Main-actor state changed since the last publish and nothing has built it yet (a control work-queue frame):
    /// ``fresh()`` builds it first. Set on the main actor, read by connection tasks.
    private let stale = Atomic<Bool>(false)
    /// Builds and publishes a stale snapshot on the main actor (the App's publisher); nil: none.
    private let refresher = Mutex<(@Sendable () async -> Void)?>(nil)

    public init() {}

    /// The latest published snapshot.
    public var current: ControlSnapshot { state.withLock { $0.snapshot } }

    /// Whether main-actor state changed since the last publish and has not been built yet.
    public var isStale: Bool { stale.load(ordering: .acquiring) }

    /// Main-actor state changed: the next ``fresh()`` builds the snapshot first (a lazy publish: nothing is built
    /// until a read needs it).
    public func markStale() { stale.store(true, ordering: .releasing) }

    /// Sets the closure that builds and publishes a stale snapshot on the main actor.
    public func setRefresher(_ refresh: (@Sendable () async -> Void)?) { refresher.withLock { $0 = refresh } }

    /// The latest snapshot, built first when main-actor state changed since the last publish (``markStale()``):
    /// what a control call reads, so it covers the writes of the calls before it.
    public func fresh() async -> ControlSnapshot {
        if isStale, let refresh = refresher.withLock({ $0 }) { await refresh() }
        return current
    }

    /// True while a reader waits for a newer topology; the publisher then
    /// publishes on the next main-actor turn instead of the next frame.
    public var hasWaiters: Bool { state.withLock { !$0.waiters.isEmpty } }

    /// Applies `update` to a copy of the current snapshot and publishes the
    /// result. Build expensive values before calling: the lock is held for
    /// the closure's duration.
    ///
    /// - Parameter rebuilt: The update holds a topology built from main-actor state now (the App's
    ///   publisher): it ends the stale mark (``markStale()``). A publish of one field (the context mask,
    ///   the catalog, settings, the daemon sequences) leaves the mark, so the next ``fresh()`` still
    ///   builds the topology: a focus change followed by a context-mask publish kept the old focus.
    @discardableResult
    public func publish(rebuilt: Bool = false, _ update: (inout ControlSnapshot) -> Void) -> UInt64 {
        let (generation, snapshot, ready) = state.withLock { state -> (UInt64, ControlSnapshot, [Waiter]) in
            update(&state.snapshot)
            if rebuilt { stale.store(false, ordering: .releasing) }
            state.snapshot.generation &+= 1
            state.snapshot.publishedAtUptimeNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard !state.waiters.isEmpty else { return (state.snapshot.generation, state.snapshot, []) }
            let snapshot = state.snapshot
            let ready = state.waiters.filter { $0.isReady(snapshot) }
            if !ready.isEmpty { state.waiters.removeAll { $0.isReady(snapshot) } }
            return (snapshot.generation, snapshot, ready)
        }
        for waiter in ready { waiter.continuation.resume(returning: snapshot) }
        return generation
    }

    /// The first published snapshot whose topology reflects daemon events up
    /// to `sequence` (the current one when it already does), or nil at
    /// `deadline` or on cancellation. Never blocks a thread.
    public func snapshot(reflecting sequence: UInt64, deadline: ContinuousClock.Instant) async -> ControlSnapshot? {
        await snapshot(reflecting: ControlSequenceBarrier(home: sequence), deadline: deadline)
    }

    /// The first published snapshot that reflects every sequence in
    /// `barrier`, or nil at `deadline` or on cancellation.
    public func snapshot(reflecting sequence: ControlSequenceBarrier, deadline: ContinuousClock.Instant) async -> ControlSnapshot? {
        await snapshot(where: { $0.reflects(sequence) }, deadline: deadline)
    }

    /// The first published snapshot for which `isReady` holds (the current
    /// one when it already does), or nil at `deadline` or on cancellation.
    /// `isReady` runs under the store's lock: keep it a cheap read.
    public func snapshot(where isReady: @escaping @Sendable (ControlSnapshot) -> Bool,
                         deadline: ContinuousClock.Instant) async -> ControlSnapshot? {
        let (ready, id) = state.withLock { state -> (ControlSnapshot?, UInt64) in
            if isReady(state.snapshot) { return (state.snapshot, 0) }
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
                    if isReady(state.snapshot) { return .some(state.snapshot) }
                    // The timer may have fired before this waiter existed (a deadline already past).
                    if Task.isCancelled || ContinuousClock.now >= deadline { return .some(nil) }
                    state.waiters.append(Waiter(id: id, isReady: isReady, continuation: continuation))
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
