import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeWorkspaceControlCommandContext: ControlCommandContext {
    var listResolution: ControlWorkspaceListResolution = .tabManagerUnavailable
    var currentResolution: ControlWorkspaceCurrentResolution = .tabManagerUnavailable

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

    func controlWorkspaceStrings() -> ControlWorkspaceStrings {
        ControlWorkspaceStrings(
            closeProtected: "close protected",
            reorderManyMissingOrder: "missing order",
            reorderManyDuplicateWorkspace: "duplicate workspace",
            reorderManyWorkspaceNotFound: "workspace not found",
            reorderManyInvalidWorkspace: "invalid workspace",
            reorderManyTabManagerUnavailable: "tab manager unavailable"
        )
    }

    func controlWorkspaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        true
    }

    func controlWorkspaceList(routing: ControlRoutingSelectors) -> ControlWorkspaceListResolution {
        listResolution
    }

    func controlWorkspaceCurrent(routing: ControlRoutingSelectors) -> ControlWorkspaceCurrentResolution {
        currentResolution
    }
}
