import Foundation

struct TerminalPointerFocusActivationPolicy: Sendable {
    func shouldForwardToTerminal(wasFocusedBeforePointerDown: Bool) -> Bool {
        wasFocusedBeforePointerDown
    }

    func shouldForwardToTerminal(currentPanelId: UUID, focusedPanelId: UUID?) -> Bool {
        focusedPanelId == currentPanelId
    }
}
