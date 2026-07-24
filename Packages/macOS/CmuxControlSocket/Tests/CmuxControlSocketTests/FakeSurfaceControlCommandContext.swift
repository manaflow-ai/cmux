import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSurfaceControlCommandContext: ControlCommandContext {
    var paneCreateResolution: ControlPaneCreateResolution = .tabManagerUnavailable
    var createResolution: ControlSurfaceCreateResolution = .tabManagerUnavailable
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
