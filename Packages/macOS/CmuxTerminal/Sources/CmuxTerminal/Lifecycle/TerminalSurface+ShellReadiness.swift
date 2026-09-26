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
        // Prompt hooks can report readiness before the editor enables DECSET
        // 2004. These editors already recognize the paste delimiters when they
        // read the buffered input. Frame it explicitly instead of consulting
        // the terminal's not-yet-enabled mode. Keep negotiated paste for other
        // shells, including macOS Bash 3.2, which has no bracketed paste support.
        let shell = engine.resolvedUserShell.map { URL(fileURLWithPath: $0).lastPathComponent }
        let framesStartupPaste = shell == "fish" || shell == "zsh"
        let text = framesStartupPaste ? "\u{1b}[200~\(command)\u{1b}[201~" : command
        guard sendTextAfterExplicitInput(
            Data(text.utf8),
            recordsExplicitInput: false,
            treatsAsPaste: !framesStartupPaste
        ).accepted else { return }
        if submitsCommand {
            _ = sendInputAfterExplicitInput("\n", recordsExplicitInput: false)
        }
    }
}
