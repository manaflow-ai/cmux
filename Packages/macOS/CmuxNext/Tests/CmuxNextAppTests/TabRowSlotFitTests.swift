@testable import CmuxNextTabs
import Testing

/// Lawrence and Leo, 2026-11-28: room kept for another tab's buttons left blank space beside crowded tabs.
@Suite struct TabRowSlotFitTests {
    @Test func roomyRowKeepsTheSlot() { #expect(TabRowSlotFit.base(kept: 120, own: 20, width: 800, tabs: 400) == 120) }
    @Test func crowdedRowGivesTheRoomBack() { #expect(TabRowSlotFit.base(kept: 120, own: 20, width: 800, tabs: 760) == 20) }
    @Test func ownNeedNeverShrinks() { #expect(TabRowSlotFit.base(kept: 20, own: 20, width: 300, tabs: 900) == 20) }
}
