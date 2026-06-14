import Testing
@testable import CmuxCommandPalette

@Suite("CommandPaletteOverlayPromotionPolicy")
struct CommandPaletteOverlayPromotionPolicyTests {
    @Test func promotesOnlyOnHiddenToVisibleTransition() {
        #expect(CommandPaletteOverlayPromotionPolicy.shouldPromote(previouslyVisible: false, isVisible: true))
        #expect(!CommandPaletteOverlayPromotionPolicy.shouldPromote(previouslyVisible: true, isVisible: true))
        #expect(!CommandPaletteOverlayPromotionPolicy.shouldPromote(previouslyVisible: false, isVisible: false))
        #expect(!CommandPaletteOverlayPromotionPolicy.shouldPromote(previouslyVisible: true, isVisible: false))
    }
}
