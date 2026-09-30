import CmuxTerminalCore
import Foundation
import Testing

@Suite
struct TerminalPointerFocusActivationPolicyTests {
    @Test
    func unfocusedPaneFocusClickDoesNotForwardToTerminal() {
        let policy = TerminalPointerFocusActivationPolicy()

        #expect(!policy.shouldForwardToTerminal(
            mouseCaptured: false,
            wasFocusedBeforePointerDown: false
        ))
    }

    @Test
    func focusedPaneClickStillForwardsToTerminal() {
        let policy = TerminalPointerFocusActivationPolicy()

        #expect(policy.shouldForwardToTerminal(
            mouseCaptured: false,
            wasFocusedBeforePointerDown: true
        ))
    }

    @Test
    func capturedMouseForwardsFocusTransferClickToTerminal() {
        let policy = TerminalPointerFocusActivationPolicy()

        #expect(policy.shouldForwardToTerminal(
            mouseCaptured: true,
            wasFocusedBeforePointerDown: false
        ))
    }

    @Test
    func matchingFocusedPanelForwardsToTerminal() {
        let panelId = UUID()
        let policy = TerminalPointerFocusActivationPolicy()

        #expect(policy.shouldForwardToTerminal(
            currentPanelId: panelId,
            focusedPanelId: panelId
        ))
    }

    @Test
    func differentFocusedPanelDoesNotForwardToTerminal() {
        let policy = TerminalPointerFocusActivationPolicy()

        #expect(!policy.shouldForwardToTerminal(
            currentPanelId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            focusedPanelId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        ))
    }

    @Test
    func missingFocusedPanelDoesNotForwardToTerminal() {
        let policy = TerminalPointerFocusActivationPolicy()

        #expect(!policy.shouldForwardToTerminal(
            currentPanelId: UUID(),
            focusedPanelId: nil
        ))
    }
}
