import AppKit
import CmuxTerminal
import CmuxTerminalCore

@MainActor
protocol TextBoxSubmitSurfaceControlling: AnyObject {
    var clipboardReadGeneration: Int { get }
    var textBoxSubmitObservationWindow: NSWindow? { get }
    var textBoxSubmitTerminalSurface: TerminalSurface? { get }

    func visibleText() -> String?
    @discardableResult
    func sendKeyText(_ text: String) -> Bool
    @discardableResult
    func sendText(_ text: String) -> Bool
    @discardableResult
    func sendNamedKey(_ keyName: String) -> TerminalSurface.NamedKeySendResult
    @discardableResult
    func sendPromptSubmission(
        _ text: String,
        submitKey: String,
        rejectIfHumanComposerBusy: Bool,
        hookRecording: ProgrammaticPromptHookRecording?
    ) -> TerminalSurface.PromptSubmissionSendResult
    @discardableResult
    func performBindingAction(_ action: String) -> Bool
    @discardableResult
    func performExplicitInputBindingAction(_ action: String) -> Bool
}

extension TextBoxSubmitSurfaceControlling {
    /// Routes the compound operation through the backing terminal when a
    /// lightweight controller does not implement its own delivery behavior.
    @discardableResult
    func sendPromptSubmission(
        _ text: String,
        submitKey: String,
        rejectIfHumanComposerBusy: Bool,
        hookRecording: ProgrammaticPromptHookRecording?
    ) -> TerminalSurface.PromptSubmissionSendResult {
        textBoxSubmitTerminalSurface?.sendPromptSubmission(
            text,
            submitKey: submitKey,
            rejectIfHumanComposerBusy: rejectIfHumanComposerBusy,
            hookRecording: hookRecording
        ) ?? .surfaceUnavailable
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
