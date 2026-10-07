import CoreGraphics
import Testing
@testable import CmuxNextTabs

private let groupMetrics: TabStripMetrics = {
    var g = m
    g.groupChipOuterInset = 2
    g.groupChipPadding = 6
    g.groupChipHeight = 16
    g.groupChipDotSize = 10
    g.groupChipMaxNameWidth = 100
    g.groupChipCountSpacing = 4
    return g
}()

private func tab(_ id: String, group: String? = nil, pinned: Bool = false) -> TabItem {
    TabItem(id: TabID(id), title: id, isPinned: pinned, groupID: group.map { TabGroupID($0) })
}

private func groupsByID(_ items: TabGroupItem...) -> [TabGroupID: TabGroupItem] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
}

@Suite("Group chip width")
struct ChipWidthTests {
    @Test func unnamedExpandedGroupIsADot() {
        let content = TabGroupChipLayout.Content(nameWidth: 0, countWidth: nil)
        #expect(TabGroupChipLayout.pillWidth(content, metrics: groupMetrics) == 10)
        #expect(TabGroupChipLayout.slotWidth(content, metrics: groupMetrics) == 14)
    }

    @Test func namedChipPadsTheName() {
        let content = TabGroupChipLayout.Content(nameWidth: 30, countWidth: nil)
        #expect(TabGroupChipLayout.pillWidth(content, metrics: groupMetrics) == 42)
    }

    @Test func collapsedChipAddsCount() {
        let named = TabGroupChipLayout.Content(nameWidth: 30, countWidth: 8)
        #expect(TabGroupChipLayout.pillWidth(named, metrics: groupMetrics) == 54, "name + spacing + count + padding")
        let unnamed = TabGroupChipLayout.Content(nameWidth: 0, countWidth: 8)
        #expect(TabGroupChipLayout.pillWidth(unnamed, metrics: groupMetrics) == 20, "count + padding")
    }

    @Test func longNamesAreClamped() {
        let content = TabGroupChipLayout.Content(nameWidth: 500, countWidth: nil)
        #expect(TabGroupChipLayout.pillWidth(content, metrics: groupMetrics) == 112)
    }
}

@Suite("Layout with groups")
struct GroupLayoutTests {
    @Test func chipTakesFixedWidthAndTabsShareTheRest() {
        let items = TabGroupOrdering.layoutItems(
            [tab("a"), tab("b", group: "g"), tab("c", group: "g")],
            groups: groupsByID(TabGroupItem(id: "g", name: "x")),
            selectedID: nil,
            chipWidths: ["g": 40]
        )
        #expect(items.map(\.id.rawValue) == ["a", TabID.groupChip("g").rawValue, "b", "c"])
        let result = TabLayoutEngine.layout(items: items, availableWidth: 340, style: .chrome, metrics: groupMetrics)
        #expect(result.slots.map(\.width) == [100, 40, 100, 100])
        #expect(result.slots[1].isGroupChip)
        #expect(result.slots[2].groupID == "g")
        #expect(result.contentWidth == 340)
    }

    @Test func collapsedMembersHaveZeroWidthBehindTheChip() {
        let items = TabGroupOrdering.layoutItems(
            [tab("a", group: "g"), tab("b", group: "g"), tab("c")],
            groups: groupsByID(TabGroupItem(id: "g", isCollapsed: true)),
            selectedID: nil,
            chipWidths: ["g": 24]
        )
        let result = TabLayoutEngine.layout(items: items, availableWidth: 1000, style: .chrome, metrics: groupMetrics)
        #expect(result.slots.map(\.width) == [24, 0, 0, 240])
        #expect(result.slots.map(\.x) == [0, 24, 24, 24])
        #expect(result.slots[1].isCollapsed && result.slots[2].isCollapsed)
    }

    @Test func collapsingGivesTheSpaceToOtherTabs() {
        let tabs = [tab("a", group: "g"), tab("b", group: "g"), tab("c"), tab("d")]
        let expanded = TabLayoutEngine.layout(
            items: TabGroupOrdering.layoutItems(tabs, groups: groupsByID(TabGroupItem(id: "g")), selectedID: nil, chipWidths: ["g": 20]),
            availableWidth: 420, style: .chrome, metrics: groupMetrics
        )
        let collapsed = TabLayoutEngine.layout(
            items: TabGroupOrdering.layoutItems(tabs, groups: groupsByID(TabGroupItem(id: "g", isCollapsed: true)), selectedID: nil, chipWidths: ["g": 20]),
            availableWidth: 420, style: .chrome, metrics: groupMetrics
        )
        #expect(expanded.slot("c")?.width == 100)
        #expect(collapsed.slot("c")?.width == 200)
    }

    @Test func pinnedTabsNeverGetAChip() {
        let items = TabGroupOrdering.layoutItems(
            [tab("p", group: "g", pinned: true), tab("a")],
            groups: groupsByID(TabGroupItem(id: "g")),
            selectedID: nil,
            chipWidths: ["g": 20]
        )
        #expect(items.allSatisfy { !$0.isGroupChip })
    }

    @Test func groupSizedGapReservesTheGroupWidth() {
        var items = TabGroupOrdering.layoutItems([tab("a"), tab("b")], groups: [:], selectedID: nil, chipWidths: [:])
        TabStripView.insertPlaceholder(TabLayoutItem(id: TabStripView.placeholderID, fixedWidth: 150), atTabIndex: 1, into: &items)
        let result = TabLayoutEngine.layout(items: items, availableWidth: 350, style: .chrome, metrics: groupMetrics)
        #expect(result.slots.map(\.id.rawValue) == ["a", TabStripView.placeholderID.rawValue, "b"])
        #expect(result.slots.map(\.width) == [100, 150, 100])
    }

    @Test func gapGoesBeforeAChipUnlessItJoinsThatGroup() {
        let base = TabGroupOrdering.layoutItems(
            [tab("a"), tab("b", group: "g")],
            groups: groupsByID(TabGroupItem(id: "g")),
            selectedID: nil,
            chipWidths: ["g": 20]
        )
        var outside = base
        TabStripView.insertPlaceholder(TabLayoutItem(id: TabStripView.placeholderID), atTabIndex: 1, into: &outside)
        #expect(outside.map(\.isGroupChip) == [false, false, true, false])
        var inside = base
        TabStripView.insertPlaceholder(TabLayoutItem(id: TabStripView.placeholderID, groupID: "g"), atTabIndex: 1, into: &inside)
        #expect(inside.map(\.isGroupChip) == [false, true, false, false])
    }
}

@Suite("Group ordering")
struct GroupOrderingTests {
    @Test func membersAreGatheredAtTheFirstMember() {
        let tabs = [tab("a", group: "g"), tab("b"), tab("c", group: "g"), tab("p", pinned: true)]
        let ordered = TabGroupOrdering.normalized(tabs, groups: ["g"])
        #expect(ordered.map(\.id.rawValue) == ["p", "a", "c", "b"])
    }

    @Test func pinnedAndUnknownGroupsAreCleared() {
        let tabs = [tab("p", group: "g", pinned: true), tab("a", group: "missing")]
        let ordered = TabGroupOrdering.normalized(tabs, groups: ["g"])
        #expect(ordered.allSatisfy { $0.groupID == nil })
    }

    @Test func collapsingMovesSelectionRightThenLeftSkippingHiddenTabs() {
        let tabs = [tab("a"), tab("b", group: "g"), tab("c", group: "g"), tab("d", group: "h"), tab("e")]
        #expect(TabGroupOrdering.selectionAfterCollapsing("g", in: tabs, collapsed: ["h"], selected: "b") == "e")
        #expect(TabGroupOrdering.selectionAfterCollapsing("g", in: Array(tabs.prefix(3)), collapsed: [], selected: "c") == "a")
        #expect(TabGroupOrdering.selectionAfterCollapsing("g", in: tabs, collapsed: [], selected: "a") == "a")
        #expect(TabGroupOrdering.selectionAfterCollapsing("g", in: [tab("b", group: "g")], collapsed: [], selected: "b") == nil)
    }

    @Test func chipIDsRoundTrip() {
        #expect(TabID.groupChip("g1").chipGroupID == "g1")
        #expect(TabID("t1").chipGroupID == nil)
    }
}
