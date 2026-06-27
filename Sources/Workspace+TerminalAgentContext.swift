import CMUXAgentLaunch
import Foundation

extension Workspace {
    /// Builds the packaged ``TerminalAgentContext`` for a panel and returns its
    /// newline-joined `key:value` string, consumed by agent detection
    /// (`TextBoxAgentDetection`) and the mobile terminal / chat RPC hosts.
    func terminalAgentContext(panel: any Panel) -> String {
        let terminalPanel = panel as? TerminalPanel
        return TerminalAgentContext(
            initialCommand: terminalPanel?.surface.initialCommand,
            tmuxStartCommand: terminalPanel?.surface.tmuxStartCommand,
            restoredAgentKindRawValue: restoredAgentSnapshotsByPanelId[panel.id]?.kind.rawValue,
            agentPIDKeys: agentPIDKeysByPanelId[panel.id] ?? []
        ).formatted
    }
}
