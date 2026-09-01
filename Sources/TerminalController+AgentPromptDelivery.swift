import CmuxTerminal

extension TerminalController {
    /// Clears a mobile chat prompt through the canonical socket-bound surface.
    func clearAgentPrompt(
        _ terminalTarget: ControlTerminalSocketTarget
    ) -> TerminalSurface.NamedKeySendResult {
        var latestAccepted: TerminalSurface.NamedKeySendResult = .sent
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            let result = terminalTarget.sendNamedKeyResult(keyName)
            guard result.accepted else { return result }
            latestAccepted = result
        }
        return latestAccepted
    }
}
