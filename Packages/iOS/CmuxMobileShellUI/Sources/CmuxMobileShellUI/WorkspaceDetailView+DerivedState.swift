import CmuxAgentGUIUI
import CmuxAgentReplica
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileWorkspace
import CoreGraphics
import SwiftUI

extension WorkspaceDetailView {
    var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == store.selectedTerminalID } ?? workspace.terminals.first
    }

    var selectedTerminalID: String? {
        selectedTerminal?.id.rawValue
    }

    var selectedToolbarSubtitle: String? {
        guard let selectedTerminalID = store.selectedTerminalID else { return nil }
        return workspace.terminals.first { $0.id == selectedTerminalID }?.name
    }

    var terminalTopPadding: CGFloat { 4 }

    /// iOS renders the workspace title as a custom principal toolbar item. Keep
    /// the system title empty there so it does not draw a second centered title.
    var systemNavigationTitle: String {
        #if os(iOS)
        ""
        #else
        workspace.name
        #endif
    }

    #if os(iOS)
    var agentGUIAvailability: AgentGUIAvailability? {
        guard let engine = store.agentSyncEngine else { return nil }
        return AgentGUIAvailability.derive(
            sessions: engine.directory.sessions,
            selectedTerminalID: selectedTerminalID
        )
    }

    var isAgentGUIVisible: Bool {
        activeSurface == .terminal && guiModeSelected && agentGUIAvailability != nil
    }

    func agentGUIDraftBinding(for sessionID: AgentSessionID) -> Binding<String> {
        Binding(
            get: { agentGUIDrafts[sessionID] },
            set: { agentGUIDrafts[sessionID] = $0 }
        )
    }
    #endif
}

#if os(iOS)
struct AgentGUIDraftState: Equatable {
    private var drafts: [AgentSessionID: String] = [:]

    subscript(sessionID: AgentSessionID) -> String {
        get { drafts[sessionID, default: ""] }
        set { drafts[sessionID] = newValue }
    }
}
#endif
