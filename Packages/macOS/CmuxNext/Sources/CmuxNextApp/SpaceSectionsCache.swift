import CmuxNextBridge
import CmuxNextCompat
import CmuxNextSidebar
import Observation

/// The rows of other spaces for the sidebar's swipe pages (R99): read once
/// when a swipe reaches a space, kept until the observed data that built
/// them (daemon stores, personal rows, window membership) changes. The
/// change marks only that entry stale, inside its own will-set, so a read
/// later in the same turn already recomputes; nothing polls, and a stale
/// entry is not recomputed until a swipe reads it.
///
/// Delivery: none. Blink's dirty bits work the same way: a change sets the
/// flag where it happens and the value is computed when it is next needed
/// (`Node::SetNeedsStyleRecalc`, third_party/blink/renderer/core/dom/node.cc).
// memory: fixed one entry per space of the person's space bar (`SidebarProfileKey`), each the row value models of one swipe page, no images
@MainActor final class SpaceSectionsCache {
    private var entries: [SidebarProfileKey: Entry] = [:]
    private(set) var computations = 0

    func sections(for key: SidebarProfileKey, compute: () -> [SidebarRowSection]) -> [SidebarRowSection] {
        if let entry = entries[key], !entry.stale.isSet { return entry.sections }
        computations += 1
        let stale = StaleMark()
        // view-observation-allow: a lazy cache; the will-set only marks the entry stale (no hop, no re-read), and a FrameObservation would recompute hidden spaces on every change
        let sections = withObservationTracking(compute) { stale.set() }
        entries[key] = Entry(sections: sections, stale: stale)
        return sections
    }

    private struct Entry {
        let sections: [SidebarRowSection]
        let stale: StaleMark
    }

    /// Set once by an entry's observation, on the thread of the change it saw.
    private nonisolated final class StaleMark: Sendable {
        private let flag = Atomic<Bool>(false)

        func set() { flag.store(true, ordering: .releasing) }

        var isSet: Bool { flag.load(ordering: .acquiring) }
    }
}
