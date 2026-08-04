import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSurfaceControlCommandContext: ControlCommandContext {
    var paneCreateResolution: ControlPaneCreateResolution = .tabManagerUnavailable
    var createResolution: ControlSurfaceCreateResolution = .tabManagerUnavailable
    var healthSnapshot: ControlSurfaceHealthSnapshot?
    var sendKeyResolution: ControlSurfaceSendResolution = .tabManagerUnavailable
    var lastCreateInputs: ControlSurfaceCreateInputs?
    var lastCreateAuthorization: ControlSocketRequestAuthorization?
    var lastSendKeyAuthorization: ControlSocketRequestAuthorization?
    var surfaceListSnapshot: ControlSurfaceListSnapshot?
    var resumeResolution: ControlSurfaceResumeResolution = .surfaceNotFound
    var resumeSetInputs: ControlSurfaceResumeSetInputs?
    var resumeClearAgentSessionEnded: Bool?
    var resumeStrings = ControlSurfaceResumeStrings(
        agentSessionEndedMustBeBoolean: "agent_session_ended must be a boolean",
        launchCommandMustBeValid: "launch_command must be valid"
    )
    var reportPWDResolution: ControlSurfaceReportPWDResolution = .recorded(surfaceID: UUID())
    var reportedPWD: (workspaceID: UUID, requestedSurfaceID: UUID?, path: String)?
    var reportGitResolution: ControlSurfaceReportGitBranchResolution = .recorded(surfaceID: UUID())
    var reportedGit: (workspaceID: UUID, requestedSurfaceID: UUID?, branch: String, isDirty: Bool?)?
    var clearedGit: (workspaceID: UUID, requestedSurfaceID: UUID?)?

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
        inputs: ControlSurfaceCreateInputs,
        requestOrigin: ControlRequestOrigin
    ) -> ControlSurfaceCreateResolution {
        lastCreateInputs = inputs
        if case .socket(let authorization) = requestOrigin {
            lastCreateAuthorization = authorization
        } else {
            lastCreateAuthorization = nil
        }
        return createResolution
    }

    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? {
        healthSnapshot
    }

    func controlSurfaceApplicationStrings() -> ControlSurfaceApplicationStrings {
        ControlSurfaceApplicationStrings(
            splitUnsupported: "application split unsupported",
            invalidWindowID: "invalid native window ID",
            invalidProcessID: "invalid application process ID",
            invalidFrameRate: "invalid application frame rate"
        )
    }

    nonisolated func controlSurfaceInputStrings() -> ControlSurfaceInputStrings {
        ControlSurfaceInputStrings(
            inputQueueFull: "queue full",
            surfaceUnavailable: "surface unavailable",
            processExited: "process exited"
        )
    }

    func controlSurfaceSendKey(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        key: String,
        requestOrigin: ControlRequestOrigin
    ) -> ControlSurfaceSendResolution {
        if case .socket(let authorization) = requestOrigin {
            lastSendKeyAuthorization = authorization
        } else {
            lastSendKeyAuthorization = nil
        }
        return sendKeyResolution
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
        agentSessionEnded: Bool
    ) -> ControlSurfaceResumeResolution {
        resumeClearAgentSessionEnded = agentSessionEnded
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
}
