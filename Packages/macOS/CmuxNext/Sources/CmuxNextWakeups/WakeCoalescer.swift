import Foundation
import CmuxNextCompat

/// Runs deadlines that may come a little early on a wake that already happened, so an idle app's periodic
/// checks share one wake instead of each taking its own (plans/cmux-next/idle-wakeups.md).
///
/// macOS counts a wakeup each time a timer wakes one of the app's threads. A ``DemandTimer`` made with an
/// `early` window registers here when it is scheduled: from `deadline - early` on, any wake that calls
/// ``wake()`` runs it at once (a ``DemandTimer`` deadline that fires, each main run loop wake). Only when no
/// wake comes inside the window does its own deadline wake the app. A deadline with no `early` never rides.
///
/// ``wake()`` is cheap when nothing is due: one atomic load and one clock read. Entries run outside the lock.
/// The app's one coalescer is ``WakeupLedger/coalescer`` of the shared ledger.
public final class WakeCoalescer: Sendable {

    private struct Entry {
        /// When the window opens (``now`` nanoseconds).
        let opensAt: UInt64
        let run: @Sendable () -> Void
    }

    private let now: @Sendable () -> UInt64
    private let entries = Mutex<[UInt64: Entry]>([:])
    /// The earliest `opensAt`, `.max` when there is none (the fast path's only read).
    private let earliest = Atomic<UInt64>(.max)
    private let nextID = Atomic<UInt64>(0)

    /// - Parameter now: Monotonic nanoseconds (tests pass a manual clock's).
    public init(now: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime) {
        self.now = now
    }

    /// The current time on the coalescer's clock.
    public var nanoseconds: UInt64 { now() }

    /// A new entry id (one per timer).
    func makeID() -> UInt64 { nextID.add(1, ordering: .relaxed).newValue }

    /// Adds or replaces entry `id`: `run` goes on the first wake at or after `opensAt`.
    func add(_ id: UInt64, opensAt: UInt64, run: @escaping @Sendable () -> Void) {
        entries.withLock { entries in
            entries[id] = Entry(opensAt: opensAt, run: run)
            if opensAt < earliest.load(ordering: .relaxed) { earliest.store(opensAt, ordering: .relaxed) }
        }
    }

    func remove(_ id: UInt64) {
        entries.withLock { entries in
            guard let removed = entries.removeValue(forKey: id) else { return }
            if removed.opensAt <= earliest.load(ordering: .relaxed) { recomputeEarliest(entries) }
        }
    }

    /// A wake happened: runs every entry whose window is open.
    public func wake() {
        guard earliest.load(ordering: .relaxed) != .max else { return }
        let at = now()
        guard earliest.load(ordering: .relaxed) <= at else { return }
        let due: [@Sendable () -> Void] = entries.withLock { entries in
            let open = entries.filter { $0.value.opensAt <= at }
            guard !open.isEmpty else { return [] }
            for id in open.keys { entries.removeValue(forKey: id) }
            recomputeEarliest(entries)
            return open.sorted { $0.value.opensAt < $1.value.opensAt }.map(\.value.run)
        }
        for run in due { run() }
    }

    /// Under the entries' lock.
    private func recomputeEarliest(_ entries: [UInt64: Entry]) {
        earliest.store(entries.values.map(\.opensAt).min() ?? .max, ordering: .relaxed)
    }
}
