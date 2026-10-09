@testable import CmuxNextApp
import Testing

/// Rapid switching 4 (Leo 2026-10-09): Home's tabs offer no promote entry
/// and the promote actions refuse them; the App Store has no tabs.
@MainActor
struct TabPromotionTests {
    @Test func homeKeepsItsTabs() {
        #expect(TabPromotion.staysPut(kind: "home"))
        #expect(!TabPromotion.staysPut(kind: nil))
        #expect(!TabPromotion.staysPut(kind: "workspace"))
    }

    @Test func aHomeTabsMenuHasNoPromoteEntries() {
        #expect(Set(TabPromotion.menuRemovals(kind: "home")) == Set(TabPromotion.actions))
        #expect(TabPromotion.menuRemovals(kind: nil).isEmpty)
    }

    @Test func thePromoteActionsRefuseAHomeTab() {
        #expect(TabPromotion.refusal(kind: "home") != nil)
        #expect(TabPromotion.refusal(kind: nil) == nil)
    }
}
