import CmuxTerminal

extension TerminalController {
    /// Clears the agent TUI's current prompt through the same line-editor path
    /// used by mobile chat before a composed prompt is pasted.
    func clearAgentPrompt(_ terminalPanel: TerminalPanel) -> TerminalSurface.NamedKeySendResult {
        var latestAccepted: TerminalSurface.NamedKeySendResult = .sent
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            let result = terminalPanel.sendNamedKeyResult(keyName)
            guard result.accepted else { return result }
            latestAccepted = result
        }
        return latestAccepted
    }
}
