internal import Foundation

extension TerminalSurface {
    /// Delivers this generation's startup input once, after shell integration reports readiness.
    ///
    /// Callers must validate the reporting terminal lifecycle before forwarding the prompt.
    /// Surface transfers retain the gate on the surface itself; no timer or replay is needed.
    @MainActor
    public func shellDidBecomeReadyForStartupInput() {
        guard surface != nil,
              let input = startupInputGate.takeForPrompt(generation: terminalLifecycleId) else { return }
        // Paste the command literally so vi normal mode cannot consume its
        // leading characters as motions. Keep the final Enter outside the
        // paste: a newline inside bracketed paste only edits the command line.
        let submitsCommand = input.hasSuffix("\n")
        let command = submitsCommand ? String(input.dropLast()) : input
        guard sendTextAfterExplicitInput(
            Data(command.utf8),
            recordsExplicitInput: false
        ).accepted else { return }
        if submitsCommand {
            _ = sendInputAfterExplicitInput("\n", recordsExplicitInput: false)
        }
    }
}
