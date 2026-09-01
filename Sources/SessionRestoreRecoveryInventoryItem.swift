import CMUXAgentLaunch
import Foundation

/// One restored panel that stayed visible because automatic continuation was unsafe.
struct SessionRestoreRecoveryInventoryItem: Equatable, Sendable {
    let tabID: UUID
    let panelID: UUID
    let agentName: String?
    let route: AgentRestoreRoute?
    let checkpointID: String?
    let savedWorkingDirectory: String

    init(
        tabID: UUID,
        panelID: UUID,
        savedWorkingDirectory: String,
        snapshot: SessionRestorableAgentSnapshot?
    ) {
        self.tabID = tabID
        self.panelID = panelID
        self.savedWorkingDirectory = savedWorkingDirectory
        agentName = snapshot?.agentDisplayName
        checkpointID = snapshot?.sessionId
        route = snapshot.map { snapshot in
            AgentRestoreRouteClassifier().route(for: AgentRestoreRequest(
                mode: snapshot.kind.restoreMode == .relaunchCommand ? .relaunchAgent : .resumeAgent,
                kind: snapshot.kind.rawValue,
                checkpointID: snapshot.sessionId,
                source: "session-restore",
                workingDirectory: savedWorkingDirectory,
                environment: snapshot.launchCommand?.environment ?? [:],
                launchCommand: snapshot.launchCommand,
                preparedArguments: nil,
                observedPermissionMode: snapshot.permissionMode
            ))
        }
    }
}
