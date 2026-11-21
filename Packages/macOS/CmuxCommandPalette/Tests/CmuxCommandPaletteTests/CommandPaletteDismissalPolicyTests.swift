import CoreGraphics
import Testing
@testable import CmuxCommandPalette

@Suite("CommandPaletteDismissalPolicy")
struct CommandPaletteDismissalPolicyTests {
    private let outsideClick = CommandPaletteInteractionDismissal.pointer(
        CommandPalettePointerEvent(isInObservedWindow: true, locationInWindow: CGPoint(x: 4, y: 4))
    )

    @Test func thePaletteClosesOnEveryInteraction() {
        let policy = CommandPaletteDismissalPolicy.closesOnAnyInteraction
        #expect(policy.dismisses(.windowResignedKey))
        #expect(policy.dismisses(outsideClick))
        #expect(policy.dismisses(.mainMenuBeganTracking))
    }

    @Test func aPanelThatStaysOpenAcrossKeyChangesStillClosesOnAClickOrTheMenu() {
        let policy = CommandPaletteDismissalPolicy.staysOpenAcrossKeyChanges
        #expect(!policy.dismisses(.windowResignedKey))
        #expect(policy.dismisses(outsideClick))
        #expect(policy.dismisses(.mainMenuBeganTracking))
    }
}
