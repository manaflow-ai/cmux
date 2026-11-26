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

    /// A tab replaced by another keeps the pane's tab count; the replaced tab's need still goes.
    /// A chat whose tools took more than their need (its rolling summary, an accessory of the row) keeps that room
    /// while another tab is selected, so the tabs do not take the summary's room and give it back; whether its tools
    /// fit the row is still decided by the need alone.
    @Test func aChatKeepsItsSummarysRoomWhileAnotherTabIsSelected() {
        var slots = PaneTrailingSlots()
        let tabs = [TabItem(id: TabID("a"), title: "A"), TabItem(id: TabID("b"), title: "B")]
        slots.record(.init(intrinsic: 40, shared: 8, tools: 150, taken: 400), for: TabID("a"), live: tabs)
        slots.record(.init(intrinsic: 40), for: TabID("b"), live: tabs)
        #expect(slots.reserve(in: 1200, besides: TabID("b")) == 408)
        // Under the need's fit, the taken width is capped at the half the strip gives up.
        #expect(slots.reserve(in: 700, besides: TabID("b")) == 8 + (700 - 8) / 2)
        // Too narrow for the need: the toolbar alone, as before.
        #expect(slots.reserve(in: 200, besides: TabID("b")) == 40)
    }

    @Test func aReplacedTabTakesNoRoom() {
        var slots = PaneTrailingSlots()
        let a = TabItem(id: TabID("a"), title: "A"), b = TabItem(id: TabID("b"), title: "B"), c = TabItem(id: TabID("c"), title: "C")
        slots.record(.init(intrinsic: 40, shared: 8, tools: 150), for: a.id, live: [a, b])
        slots.record(.init(intrinsic: 40), for: b.id, live: [b, c])
        #expect(slots.reserve(in: 900, besides: b.id) == 0)
    }
}
