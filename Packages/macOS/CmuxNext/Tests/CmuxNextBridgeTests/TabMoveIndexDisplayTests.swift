import Testing
@testable import CmuxNextBridge

/// R38: a strip drop's display index is not the pane's index. Before, the
/// display index went to the daemon unchanged, so a strip that hides or
/// regroups tabs put the tab somewhere else than where it was dropped.
@Suite struct TabMoveIndexDisplayTests {
    @Test func theSameOrderMapsOneToOne() {
        let order = ["a", "b", "c"]
        #expect(TabMoveIndex.paneFinalIndex(display: order, moving: "c", displayIndex: 0, pane: order) == 0)
        #expect(TabMoveIndex.paneFinalIndex(display: order, moving: "a", displayIndex: 2, pane: order) == 2)
        #expect(TabMoveIndex.paneFinalIndex(display: order, moving: "b", displayIndex: 1, pane: order) == 1)
    }

    @Test func aHiddenClosingTabDoesNotShiftTheDrop() {
        // Pane a x b c, x closing (hidden): the strip shows a b c.
        let pane = ["a", "x", "b", "c"]
        // a to the end: after c.
        #expect(TabMoveIndex.paneFinalIndex(display: ["a", "b", "c"], moving: "a", displayIndex: 2, pane: pane) == 3)
        // c to the front: before a.
        #expect(TabMoveIndex.paneFinalIndex(display: ["a", "b", "c"], moving: "c", displayIndex: 0, pane: pane) == 0)
    }

    @Test func aPinnedTabShownFirstMapsToItsPaneSlot() {
        // Pane a p b, p pinned: the strip shows p a b. b between p and a.
        #expect(TabMoveIndex.paneFinalIndex(display: ["p", "a", "b"], moving: "b", displayIndex: 1, pane: ["a", "p", "b"]) == 0)
    }

    @Test func groupMembersShownTogetherMapToTheirPaneSlots() {
        // Pane g1 x g2, g1 g2 grouped: the strip shows g1 g2 x. x to the front.
        #expect(TabMoveIndex.paneFinalIndex(display: ["g1", "g2", "x"], moving: "x", displayIndex: 0, pane: ["g1", "x", "g2"]) == 0)
        // g1 after x: the strip order g2 x g1.
        #expect(TabMoveIndex.paneFinalIndex(display: ["g1", "g2", "x"], moving: "g1", displayIndex: 2, pane: ["g1", "x", "g2"]) == 2)
    }

    @Test func appLocalTabsAfterTheDropDoNotCount() {
        // The strip shows a b then app-local l: a after l is the pane's end.
        #expect(TabMoveIndex.paneFinalIndex(display: ["a", "b", "l"], moving: "a", displayIndex: 2, pane: ["a", "b"]) == 1)
    }
}

/// A tab dropped into a group: the strip reports the display index, the
/// daemon takes a position inside the group. Before, the display index
/// went unchanged, so the tab landed elsewhere in the group (or at its end).
@Suite struct TabMoveIndexGroupTests {
    @Test func aDropCountsOnlyTheGroupMembersBeforeIt() {
        // Strip: a [g1 g2 g3] b. b dropped between g1 and g2 (display 2).
        let display = ["a", "g1", "g2", "g3", "b"], members: Set = ["g1", "g2", "g3"]
        #expect(TabMoveIndex.groupIndex(display: display, members: members, moving: "b", displayIndex: 2) == 1)
        // Before g1 (display 1): first in the group.
        #expect(TabMoveIndex.groupIndex(display: display, members: members, moving: "b", displayIndex: 1) == 0)
        // After g3 (display 4): last.
        #expect(TabMoveIndex.groupIndex(display: display, members: members, moving: "b", displayIndex: 4) == 3)
    }

    @Test func aTabFromTheLeftDoesNotCountItself() {
        // Strip: a [g1 g2] b. a dropped between g1 and g2: a's final index is 1.
        #expect(TabMoveIndex.groupIndex(display: ["a", "g1", "g2", "b"], members: ["g1", "g2"], moving: "a", displayIndex: 1) == 1)
    }
}
