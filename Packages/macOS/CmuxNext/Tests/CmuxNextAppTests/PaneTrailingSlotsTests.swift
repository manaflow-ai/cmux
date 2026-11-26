@testable import CmuxNextTabs
import Testing

/// `PaneTrailingSlots`: the strip gives up the most any tab of the pane takes at the row's trailing end (Leo 2026-11-07,
/// Trace-ID ask-11b77f340e; `PaneTabRowStaysPutTests` drives it through a pane).
@MainActor struct PaneTrailingSlotsTests {
    /// The trailing slot is the most any tab of the pane takes, and a tab the pane no longer holds takes none.
    @Test func theSlotIsTheWidestTabsAndForgetsClosedTabs() {
        var slots = PaneTrailingSlots()
        let tabs = [TabItem(id: TabID("a"), title: "A"), TabItem(id: TabID("b"), title: "B")]
        slots.record(.init(intrinsic: 40, shared: 8, tools: 150), for: TabID("a"), live: tabs)
        slots.record(.init(intrinsic: 40), for: TabID("b"), live: tabs)
        #expect(slots.reserve(in: 900, besides: TabID("b")) == 158)
        #expect(slots.reserve(in: 900, besides: TabID("a")) == 40)
        // Too narrow for the chat's tools in the row: its toolbar alone.
        #expect(slots.reserve(in: 250, besides: TabID("b")) == 40)
        #expect(slots.parkedChatToolbar == 8)
        slots.record(.init(intrinsic: 40), for: TabID("b"), live: [tabs[1]])
        #expect(slots.reserve(in: 900, besides: TabID("b")) == 0)
    }

    /// A chat's rolling summary (an accessory of the row) is never kept in the slot for a tab not selected: it left an
    /// empty gap at the row's end that the tabs were squeezed and scrolled beside (#53314). Only the tools' need counts.
    @Test func aChatsSummaryTakesNoRoomWhileAnotherTabIsSelected() {
        var slots = PaneTrailingSlots()
        let tabs = [TabItem(id: TabID("a"), title: "A"), TabItem(id: TabID("b"), title: "B")]
        slots.record(.init(intrinsic: 40, shared: 8, tools: 150), for: TabID("a"), live: tabs)
        slots.record(.init(intrinsic: 40), for: TabID("b"), live: tabs)
        #expect(slots.reserve(in: 1200, besides: TabID("b")) == 158)
        // Too narrow for the need: the toolbar alone, as before.
        #expect(slots.reserve(in: 200, besides: TabID("b")) == 40)
    }

    /// The tabs come before a row's accessories: an accessory takes only what is left once every tab has its full width,
    /// and none of a full row (#53314).
    @Test func anAccessoryTakesOnlyWhatTheTabsLeave() {
        // 1200pt row, 200pt toolbar and tools, tabs that need 600pt: 400pt free, a 300pt summary fits whole.
        #expect(TabRowAccessoryFit.fit(base: 200, accessory: 300, width: 1200, tabs: 600) == (slot: 500, room: 400))
        // Tabs that need 900pt leave 100pt: the summary gets at most that (the page hides it under its minimum).
        #expect(TabRowAccessoryFit.fit(base: 200, accessory: 300, width: 1200, tabs: 900) == (slot: 300, room: 100))
        // A full row (tabs past the room, or a tab that fills the strip): nothing for the summary.
        #expect(TabRowAccessoryFit.fit(base: 200, accessory: 300, width: 1200, tabs: 2000) == (slot: 200, room: 0))
        #expect(TabRowAccessoryFit.fit(base: 200, accessory: 300, width: 1200, tabs: .infinity) == (slot: 200, room: 0))
    }

    @Test func aReplacedTabTakesNoRoom() {
        var slots = PaneTrailingSlots()
        let a = TabItem(id: TabID("a"), title: "A"), b = TabItem(id: TabID("b"), title: "B"), c = TabItem(id: TabID("c"), title: "C")
        slots.record(.init(intrinsic: 40, shared: 8, tools: 150), for: a.id, live: [a, b])
        slots.record(.init(intrinsic: 40), for: b.id, live: [b, c])
        #expect(slots.reserve(in: 900, besides: b.id) == 0)
    }
}
