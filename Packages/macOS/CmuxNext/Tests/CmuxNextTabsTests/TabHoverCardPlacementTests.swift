import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

/// R109: a strip at the bottom of its pane opens tab hover cards upward,
/// so a card never covers the strip or leaves the window.
@MainActor @Suite struct TabHoverCardPlacementTests {
    @Test func aBottomStripOpensCardsAbove() {
        #expect(TabHoverCardController.placement(for: .top) == .below)
        #expect(TabHoverCardController.placement(for: .bottom) == .above)
    }
}
