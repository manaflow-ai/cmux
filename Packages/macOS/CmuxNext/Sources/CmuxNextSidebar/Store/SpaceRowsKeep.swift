import CmuxNextCompat
import CmuxNextWakeups
import Observation

/// The rows pass's computed sections of each space the window showed, so a switch back to a space where nothing
/// changed computes nothing that grows with the session (SPACE SWITCH 3, F3: the pass walked every workspace of the
/// session on each switch: the room filter, the personal order, the row mapping and the member filter). Chromium
/// does the same for a tab switch: it shows the kept state of the tab and does not build the tab strip model again.
///
/// The kept rows of a space show again only when all of this holds, each part checked in O(1) or in O(rows of that space):
/// - No value the compute read changed. One observation registration covers the compute (the values that run the
///   rows pass again: the stores' workspace lists and personal state, the window registry, the sidebar document's
///   projection, the machines, the closes under way). Its will-set callback sets the entry's flag inside the
///   write, with no hop, so a pass in the turn of the change reads it.
/// - The by-value parts are equal (`inputs`, `stamp`).
/// - The row feed still holds each row and each listing of the space, and no listing's rule must run again
///   (`SidebarRowFeed.names(_:)`).
/// - The run is the first one for another space than the last run's. A run for the space the sidebar lists already
///   computes as before and the kept rows of the other spaces go: such a run can have a cause no stamp names.
///
/// A hit still computes what the caller computes around it (the pending rows' listing, the decorations, the space
/// bar, the band's layout), the feed's fill and the model's set.
@MainActor
public final class SpaceRowsKeep {
    private struct Kept {
        var sections: [SidebarSection]
        var launching: Bool
        var failed: Set<MachineID>
        var roll: SidebarRowFeed.Roll
    }

    /// One space under one stamp: at most one registration armed at a time (a new one only after the last fired).
    @MainActor private final class Entry {
        let stamp: AnyHashable
        let tracking = SingleArmedTracking()
        let signal: SpaceRowsSignal
        var kept: Kept?

        init(stamp: AnyHashable, wake: SpaceRowsWake) {
            self.stamp = stamp
            signal = SpaceRowsSignal(wake: wake)
        }
    }

    private var entries: [ProfileKey: Entry] = [:]
    /// Read by every run of the pass; moves when a value any kept or computed rows were made from changes.
    private let wake = SpaceRowsWake()
    /// The space of the last run.
    private var shown: ProfileKey?
    /// Runs that computed the sections, and runs that showed kept ones (tests).
    public private(set) var computes = 0
    public private(set) var hits = 0

    public init() {}

    /// The rows of space `key` for the rows pass: the kept ones when they are proven current, else `compute`'s
    /// (kept for the next switch back unless `keeps` is false). `compute` begins the feed's pass itself with `inputs`.
    /// `stamp`: the by-value parts the rows are made from that no observation tells of.
    public func rows(for key: ProfileKey, inputs: AnyHashable, stamp: AnyHashable, keeps: Bool, feed: SidebarRowFeed,
                     compute: () -> ([SidebarSection], Bool, Set<MachineID>)) -> ([SidebarSection], Bool, Set<MachineID>) {
        _ = wake.epoch // every run: the pass runs again when a value these rows were made from changes
        let full = AnyHashable([inputs, stamp])
        // Another stamp: what the compute reads may be other values than the armed registration covers.
        let entry = entries[key].flatMap { $0.stamp == full ? $0 : nil } ?? Entry(stamp: full, wake: wake)
        entries[key] = entry
        let switched = shown != key
        if !switched { for (other, hidden) in entries where other != key { hidden.kept = nil } }
        shown = key
        if switched, keeps, !entry.signal.isStale, var kept = entry.kept {
            feed.beginPass(inputs: inputs)
            if let moved = feed.names(&kept.roll) {
                // Rows mapped again since they were kept (a status that changed while the space was hidden).
                kept.sections = SidebarSection.patching(moved, in: kept.sections)
                entry.kept = kept
                hits += 1
                return (kept.sections, kept.launching, kept.failed)
            }
        }
        computes += 1
        entry.kept = nil
        entry.signal.clear() // before the compute: a write inside it leaves the rows stale
        let (sections, launching, failed) = entry.tracking.track(shape: [], compute, onChange: { [signal = entry.signal] in signal.mark() })
        if keeps, !launching { entry.kept = Kept(sections: sections, launching: launching, failed: failed, roll: feed.roll()) }
        return (sections, launching, failed)
    }
}

/// Set inside the write of a value a space's rows were made from (the will-set callback, on the writer's thread).
nonisolated fileprivate final class SpaceRowsSignal: Sendable {
    private let stale = Atomic<Bool>(true)
    private let wake: SpaceRowsWake

    init(wake: SpaceRowsWake) { self.wake = wake }

    /// A value the rows were made from is about to change: they are stale now, and the pass runs after the write.
    func mark() {
        stale.store(true, ordering: .releasing)
        MainDelivery().run { [wake] in wake.epoch &+= 1 }
    }

    func clear() { stale.store(false, ordering: .releasing) }
    var isStale: Bool { stale.load(ordering: .acquiring) }
}

/// Read by the rows pass on every run; moves when a value a space's rows were made from changes, so the pass runs again.
@MainActor @Observable
fileprivate final class SpaceRowsWake {
    var epoch: UInt64 = 0
}
