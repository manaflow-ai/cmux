import AppKit
import CmuxTerminal

@MainActor
protocol TextBoxSubmitSurfaceControlling: AnyObject {
    var clipboardReadGeneration: Int { get }
    var textBoxSubmitObservationWindow: NSWindow? { get }
    var textBoxSubmitTerminalSurface: TerminalSurface? { get }

    func visibleText() -> String?
    @discardableResult
    func sendKeyText(_ text: String, isUserInitiated: Bool) -> Bool
    @discardableResult
    func sendText(_ text: String, isUserInitiated: Bool) -> Bool
    @discardableResult
    func sendNamedKey(
        _ keyName: String,
        isUserInitiated: Bool
    ) -> TerminalSurface.NamedKeySendResult
    @discardableResult
    func performBindingAction(_ action: String) -> Bool
    @discardableResult
    func performExplicitInputBindingAction(_ action: String) -> Bool
}

extension TextBoxSubmitSurfaceControlling {
    /// Compatibility wrapper for non-user-initiated programmatic text.
    @discardableResult
    func sendText(_ text: String) -> Bool {
        sendText(text, isUserInitiated: false)
    }

    /// Compatibility wrapper for non-user-initiated translated key text.
    @discardableResult
    func sendKeyText(_ text: String) -> Bool {
        sendKeyText(text, isUserInitiated: false)
    }

    /// Compatibility wrapper for a non-user-initiated named key.
    @discardableResult
    func sendNamedKey(_ keyName: String) -> TerminalSurface.NamedKeySendResult {
        sendNamedKey(keyName, isUserInitiated: false)
    }

    /// Default for non-terminal/test controllers that own no pending restore state.
    /// `TerminalSurface` supplies its concrete cancellation-aware implementation.
    @discardableResult
    func performExplicitInputBindingAction(_ action: String) -> Bool {
        performBindingAction(action)
    }
}

extension TerminalSurface: TextBoxSubmitSurfaceControlling {
    var textBoxSubmitObservationWindow: NSWindow? {
        hostedView.window
    }

    var textBoxSubmitTerminalSurface: TerminalSurface? {
        self
    }
}
