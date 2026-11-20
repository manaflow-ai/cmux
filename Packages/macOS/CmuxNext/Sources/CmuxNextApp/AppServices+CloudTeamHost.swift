import AppKit
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine

extension AppServices: CloudTeamHost {
    func cloudTeamCall(_ path: String, _ body: [String: Any], team: String?) async throws -> [String: Any] { try await feed.call(path, body, team: team) }
    var cloudTeamSignedIn: Bool { cloud.isSignedIn }
    var cloudTeamID: String? { cloud.isSignedIn ? GitHubAppLease.backendTeam(stackProjectID: cloud.auth.configuration.stackProjectID, userID: cloud.auth.user?.id, stackTeamID: cloud.auth.teamID, managed: cloud.auth.managedTeamID != nil) : nil }
    var cloudTeamUserID: String? { (cloud.auth.user?.id).map(cloudTeamWorkerUser) }
    func cloudTeamWorkerUser(_ stackUser: String) -> String { CloudIdentity.workerUserID(stackProjectID: cloud.auth.configuration.stackProjectID, stackUserID: stackUser) }
    var cloudTeamMachineIDs: [String] { machines.cloud.map(\.machineID) }
    func cloudTeamStore(_ vm: String) -> DaemonStore? { machines.session(vm)?.daemon.store }
    func cloudTeamStatus(_ vm: String) -> String? { machines.session(vm)?.effectiveStatus.rawValue }
    var cloudTeamActiveMachine: String? { windows.active?.state.machineID }
    var cloudTeamActiveWorkspaceKey: String? { windows.active?.state.workspaceID }
    func cloudTeamWorkspace(_ id: String) -> WorkspaceModel? { machines.workspace(id: id)?.0 }
    func cloudTeamWorkspaceMachine(_ id: String) -> String? { machines.workspace(id: id)?.1.machineID }
    func cloudTeamRevealTab(_ id: String, intent: WindowActivation.Intent) -> Bool { revealTab(id, intent: intent) }
    func cloudTeamWindow(workspace key: String) -> NSWindow? { windows.reveal(workspaceID: key)?.window }
    func cloudTeamShowWindow(_ window: NSWindow, intent: WindowActivation.Intent) { showJumpWindow(window, intent) }
    var cloudTeamTokens: ThemeTokens { (windows.active?.themeScope ?? .app).tokens }
}
