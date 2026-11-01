import Foundation

/// Whether an automatic account switch may type its resume command into the respawned shell.
///
/// The automatic switch runs unattended, so anything that reached the new shell before its
/// prompt (typeahead, a paste, a socket `send`) may sit on the prompt line, and the resume
/// command would be appended to it. Every byte that reaches the respawned terminal passes the
/// pane's explicit-input path, so input since the respawn is the decisive signal. A custom shell
/// prompt (`user@host dir % `) can't be told from typed text on screen; the screen check adds
/// the lines the shared classifier can read as holding text or a dialog.
struct ClaudeAccountSwitchShellLine {
    /// Whether the resume command may be typed.
    ///
    /// - Parameters:
    ///   - receivedInputSinceRespawn: Whether the respawned pane received any input.
    ///   - screen: The shared classification of the respawned pane's screen.
    static func acceptsResumeInput(
        receivedInputSinceRespawn: Bool,
        screen: AgentAutoResumeCoordinator.ScreenState
    ) -> Bool {
        guard !receivedInputSinceRespawn else { return false }
        switch screen {
        case .emptyPrompt, .unknown:
            return true
        case .draft, .dialog, .codexGoalResume, .codexResumePicker:
            return false
        }
    }
}
