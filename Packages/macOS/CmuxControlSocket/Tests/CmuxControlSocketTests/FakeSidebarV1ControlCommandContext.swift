import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSidebarV1ControlCommandContext: ControlCommandContext {
    var workspaceLoadingResult: ControlSidebarWorkspaceLoadingState?
    var workspaceLoadingCall: (tabArg: String?, key: String, on: Bool)?
    // Test-only synchronous seam: calls and reads are serial within each test.
    var manualPullRequestAvailable = true
    nonisolated(unsafe) var manualPullRequestCall: (
        tabArg: String?, number: Int, label: String, url: URL, state: String, branch: String?
    )?
    nonisolated(unsafe) var manualPullRequestClearTab: String?
    nonisolated(unsafe) var statusClearCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    )?
    nonisolated(unsafe) var agentPIDClearCall: (
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool
    )?
    nonisolated(unsafe) var shellStateCall: (
        scope: ControlSidebarPanelScope,
        stateRawValue: String
    )?

    nonisolated func controlSurfaceParseShellActivityState(
        _ rawState: String
    ) -> String? {
        switch rawState {
        case "prompt": "promptIdle"
        case "running": "commandRunning"
        default: nil
        }
    }

    nonisolated func controlSidebarIsValidPullRequestState(_ raw: String) -> Bool {
        ["open", "merged", "closed"].contains(raw)
    }

    func controlSidebarAttachManualPullRequest(
        tabArg: String?,
        number: Int,
        label: String,
        url: URL,
        statusRawValue: String,
        branch: String?
    ) -> Bool {
        guard manualPullRequestAvailable else { return false }
        manualPullRequestCall = (tabArg, number, label, url, statusRawValue, branch)
        return true
    }

    func controlSidebarClearManualPullRequest(tabArg: String?) -> Bool {
        guard manualPullRequestAvailable else { return false }
        manualPullRequestClearTab = tabArg
        return true
    }

    nonisolated func controlSidebarScheduleStatusClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    ) {
        statusClearCall = (target, key, panelID)
    }

    nonisolated func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool
    ) {
        agentPIDClearCall = (target, key, panelID, clearStatus, requireOwnedKey)
    }

    nonisolated func controlSidebarScheduleScopedShellState(
        scope: ControlSidebarPanelScope,
        stateRawValue: String
    ) {
        shellStateCall = (scope, stateRawValue)
    }

    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState? {
        workspaceLoadingCall = (tabArg, key, on)
        return workspaceLoadingResult
    }
}
