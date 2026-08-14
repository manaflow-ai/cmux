import CmuxWorkspaces
import Foundation

extension TabManager {
    func makeWorkspaceForCreation(
        id: UUID? = nil,
        title: String,
        workingDirectory: String?,
        portOrdinal: Int,
        configTemplate: CmuxSurfaceConfigTemplate?,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String?,
        initialTerminalInput: String? = nil,
        initialTerminalStartupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        initialTerminalEnvironment: [String: String],
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false,
        workspaceEnvironment: [String: String] = [:],
        allowTextBoxFocusDefault: Bool = true
    ) -> Workspace {
        Workspace(
            id: id,
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: configTemplate,
            initialSurface: initialSurface,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalStartupRestoreAgent: initialTerminalStartupRestoreAgent,
            initialTerminalStartupRestoreCommitOwner: .tabManagerTopology,
            initialTerminalEnvironment: initialTerminalEnvironment,
            initialBrowserURL: initialBrowserURL,
            initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
            initialBrowserTransparentBackground: initialBrowserTransparentBackground,
            workspaceEnvironment: workspaceEnvironment,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault,
            tabDragTransferRegistry: tabDragTransferRegistry,
            settings: settings,
            closeTabWarningDefaults: closeTabWarningDefaults,
            agentChatResumeIntentRecorder: agentChatResumeIntentRecorder,
            nativeSSHConnectionBroker: nativeSSHConnectionBroker,
            chromePalette: chromePalette
        )
    }

    func makeWorkspaceForDetachedSurface(
        title: String,
        workingDirectory: String?,
        portOrdinal: Int,
        configTemplate: CmuxSurfaceConfigTemplate?,
        detachedSurface: Workspace.DetachedSurfaceTransfer
    ) -> Workspace {
        Workspace(
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: configTemplate,
            tabDragTransferRegistry: tabDragTransferRegistry,
            settings: settings,
            closeTabWarningDefaults: closeTabWarningDefaults,
            initialDetachedSurface: detachedSurface,
            agentChatResumeIntentRecorder: agentChatResumeIntentRecorder,
            nativeSSHConnectionBroker: nativeSSHConnectionBroker,
            chromePalette: chromePalette
        )
    }
}
