@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextSidebar
import Observation
import Testing

/// The swipe pages' cache of other spaces' rows: a change to what an entry read marks it stale in
/// the change's own turn, with no hop, and the entry is recomputed only when it is read again.
@MainActor @Suite struct SpaceSectionsCacheTests {
    @MainActor @Observable final class Rows {
        var count = 1
        var unrelated = 0
    }

    private static let section = SidebarRowSection(kind: .machine(SidebarMachine(id: MachineID("local"), name: "Mac", kind: .local)),
                                                   nodes: [])

    private static func read(_ cache: SpaceSectionsCache, _ rows: Rows, key: SidebarProfileKey = SidebarProfileKey("p")) -> Int {
        cache.sections(for: key) { Array(repeating: section, count: rows.count) }.count
    }

    @Test func aChangeIsSeenByAReadInTheSameTurn() {
        let cache = SpaceSectionsCache(), rows = Rows()
        #expect(Self.read(cache, rows) == 1)
        rows.count = 3
        // No await, no run loop pass: the will-set marked the entry stale.
        #expect(Self.read(cache, rows) == 3, "a read right after the change got the old rows")
        #expect(cache.computations == 2)
    }

    @Test func aStaleEntryIsNotRecomputedUntilItIsRead() {
        let cache = SpaceSectionsCache(), rows = Rows()
        _ = Self.read(cache, rows)
        for count in 2...50 { rows.count = count }
        #expect(cache.computations == 1, "a change recomputed a space nobody is swiping to")
        #expect(Self.read(cache, rows) == 50)
        #expect(cache.computations == 2, "fifty changes cost more than one recompute at the read")
    }

    @Test func anUnreadChangeKeepsTheEntryAndOtherKeysKeepTheirs() {
        let cache = SpaceSectionsCache(), rows = Rows(), other = Rows()
        _ = Self.read(cache, rows)
        _ = Self.read(cache, other, key: SidebarProfileKey("q"))
        rows.unrelated += 1
        other.count = 4
        #expect(Self.read(cache, rows) == 1)
        #expect(cache.computations == 2, "a change the entry did not read invalidated it")
        #expect(Self.read(cache, other, key: SidebarProfileKey("q")) == 4)
        #expect(cache.computations == 3)
    }
}
