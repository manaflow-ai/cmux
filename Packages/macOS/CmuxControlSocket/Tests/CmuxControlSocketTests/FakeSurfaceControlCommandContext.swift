import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSurfaceControlCommandContext: ControlCommandContext {
    var paneCreateResolution: ControlPaneCreateResolution = .tabManagerUnavailable
    var createResolution: ControlSurfaceCreateResolution = .tabManagerUnavailable
    var surfaceListSnapshot: ControlSurfaceListSnapshot?
    var resumeResolution: ControlSurfaceResumeResolution = .surfaceNotFound
    var resumeSetInputs: ControlSurfaceResumeSetInputs?
    var resumeClearAgentSessionEnded: Bool?
    var resumeClearExpectedBindingUpdatedAt: Double?
    var resumeClearAgentMutationGuard: ControlSidebarAgentMutationGuard?
    var resumeStrings = ControlSurfaceResumeStrings(
        agentSessionEndedMustBeBoolean: "agent_session_ended must be a boolean",
        invalidExpectedUpdatedAt: "invalid expected updated at",
        launchCommandMustBeValid: "launch_command must be valid",
        agentMutationGuardMustBeValid: "agent mutation guard must be valid"
    )
    var reportPWDResolution: ControlSurfaceReportPWDResolution = .recorded(surfaceID: UUID())
    var reportedPWD: (workspaceID: UUID, requestedSurfaceID: UUID?, path: String)?
    var reportGitResolution: ControlSurfaceReportGitBranchResolution = .recorded(surfaceID: UUID())
    var reportedGit: (workspaceID: UUID, requestedSurfaceID: UUID?, branch: String, isDirty: Bool?)?
    var clearedGit: (workspaceID: UUID, requestedSurfaceID: UUID?)?
    var reportShellStateResolution: ControlSurfaceReportShellStateResolution = .pending
    var reportedShellState: (
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        terminalLifecycleID: UUID?,
        stateRawValue: String
    )?

    func controlWindowSummaries() -> [ControlWindowSummary] { [] }
    func controlResolveCurrentWindow(routing: ControlRoutingSelectors) -> ControlCurrentWindowResolution {
        .tabManagerUnavailable
    }
    func controlFocusWindow(id: UUID) -> Bool { false }
    func controlCreateWindowAndActivate() -> UUID? { nil }
    func controlCloseWindow(id: UUID) -> Bool { false }
    func controlAvailableDisplays() -> [ControlDisplayInfo] { [] }
    func controlWindowExists(id: UUID) -> Bool { false }
    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String? { nil }
    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? { nil }
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { true }
    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot? {
        surfaceListSnapshot
    }
    func controlPaneRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { true }

    func controlPaneCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution {
        paneCreateResolution
    }

    func controlSurfaceCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceCreateInputs
    ) -> ControlSurfaceCreateResolution {
        createResolution
    }

    func controlSurfaceResumeSet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        inputs: ControlSurfaceResumeSetInputs
    ) -> ControlSurfaceResumeResolution {
        resumeSetInputs = inputs
        return resumeResolution
    }

    func controlSurfaceResumeStrings() -> ControlSurfaceResumeStrings {
        resumeStrings
    }

    func controlSurfaceResumeGet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool
    ) -> ControlSurfaceResumeResolution {
        resumeResolution
    }

    func controlSurfaceResumeClear(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        expectedCheckpointID: String?,
        expectedSource: String?,
        agentSessionEnded: Bool,
        expectedBindingUpdatedAt: Double?,
        agentMutationGuard: ControlSidebarAgentMutationGuard?
    ) -> ControlSurfaceResumeResolution {
        resumeClearAgentSessionEnded = agentSessionEnded
        resumeClearExpectedBindingUpdatedAt = expectedBindingUpdatedAt
        resumeClearAgentMutationGuard = agentMutationGuard
        return resumeResolution
    }

    func controlSurfaceReportPWD(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        path: String
    ) -> ControlSurfaceReportPWDResolution {
        reportedPWD = (workspaceID, requestedSurfaceID, path)
        return reportPWDResolution
    }

    func controlSurfaceReportGitBranch(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        branch: String,
        isDirty: Bool?
    ) -> ControlSurfaceReportGitBranchResolution {
        reportedGit = (workspaceID, requestedSurfaceID, branch, isDirty)
        return reportGitResolution
    }

    func controlSurfaceClearGitBranch(
        workspaceID: UUID,
        requestedSurfaceID: UUID?
    ) -> ControlSurfaceReportGitBranchResolution {
        clearedGit = (workspaceID, requestedSurfaceID)
        return reportGitResolution
    }

    nonisolated func controlSurfaceParseShellActivityState(
        _ rawState: String
    ) -> String? {
        switch rawState {
        case "prompt": "promptIdle"
        case "running": "commandRunning"
        case "unknown": "unknown"
        default: nil
        }
    }

    func controlSurfaceReportShellState(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        terminalLifecycleID: UUID?,
        stateRawValue: String
    ) -> ControlSurfaceReportShellStateResolution {
        reportedShellState = (
            workspaceID,
            requestedSurfaceID,
            terminalLifecycleID,
            stateRawValue
        )
        return reportShellStateResolution
    }
}
