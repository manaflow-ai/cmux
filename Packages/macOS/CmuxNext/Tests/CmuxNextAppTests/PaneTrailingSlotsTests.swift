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
}
