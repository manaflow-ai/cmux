extension TerminalSurface {
    /// Delivers this generation's startup input once, after shell integration reports readiness.
    ///
    /// Callers must validate the reporting terminal lifecycle before forwarding the prompt.
    /// Surface transfers retain the gate on the surface itself; no timer or replay is needed.
    @MainActor
    public func shellDidBecomeReadyForStartupInput() {
        guard surface != nil,
              let input = startupInputGate.takeForPrompt(generation: terminalLifecycleId) else { return }
        sendStartupInputAfterExplicitInput(input)
    }

    /// Delivers startup text through Ghostty's paste API, then submits one trailing line ending.
    ///
    /// Ghostty selects bracketed paste when the receiving program advertises mode 2004 and
    /// keeps the fallback non-bracketed paste path inside libghostty. Splitting the final line
    /// ending lets bracketed-paste-aware shells receive the complete command atomically while
    /// the Return key still executes it.
    @MainActor
    private func sendStartupInputAfterExplicitInput(_ input: String) {
        let submitsTrailingLineEnding = input.hasSuffix("\r\n")
            || input.hasSuffix("\n")
            || input.hasSuffix("\r")
        let pasteText: String
        if input.hasSuffix("\r\n") {
            pasteText = String(input.dropLast(2))
        } else if submitsTrailingLineEnding {
            pasteText = String(input.dropLast())
        } else {
            pasteText = input
        }

        if !pasteText.isEmpty {
            guard sendTextAfterExplicitInput(Data(pasteText.utf8)).accepted else { return }
        }
        guard submitsTrailingLineEnding,
              let submitKey = pendingKeyEvent(for: "return") else {
            return
        }
        _ = sendNamedKeyAfterExplicitInput(submitKey)
    }
}
