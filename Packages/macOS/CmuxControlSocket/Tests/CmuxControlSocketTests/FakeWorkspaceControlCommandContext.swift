import Foundation
import CmuxSettings
@testable import CmuxControlSocket

@MainActor
final class FakeWorkspaceControlCommandContext: ControlCommandContext {
    nonisolated let currentRemotePTYLifecycleOwner: ControlRemotePTYLifecycleOwner?
    var listResolution: ControlWorkspaceListResolution = .tabManagerUnavailable
    var currentResolution: ControlWorkspaceCurrentResolution = .tabManagerUnavailable
    var closeResolution: ControlWorkspaceCloseResolution = .tabManagerUnavailable
    var addWorkspaceToGroupResolution: ControlWorkspaceGroupAddResolution = .tabManagerUnavailable
    var addWorkspaceToGroupCall: (
        groupID: UUID,
        workspaceID: UUID,
        placement: WorkspaceGroupNewPlacement?,
        referenceWorkspaceID: UUID?
    )?
    var terminalSessionEndResolution: ControlWorkspaceRemoteTerminalSessionEndResolution = .notFound
    var terminalSessionConnectedResolution: ControlWorkspaceRemoteTerminalSessionConnectedResolution = .notFound
    var terminalSessionEndCall: (
        workspaceID: UUID, surfaceID: UUID, relayPort: Int?,
        sessionID: String?, lifecycleID: String?, lifecycleOnly: Bool
    )?
    var terminalSessionConnectedCall: (
        workspaceID: UUID,
        surfaceID: UUID,
        authority: ControlWorkspaceRemoteTerminalAuthority
    )?

    init(currentRemotePTYLifecycleOwner: ControlRemotePTYLifecycleOwner? = nil) {
        self.currentRemotePTYLifecycleOwner = currentRemotePTYLifecycleOwner
    }

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
            closeFailed: "close failed",
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

    func controlCloseWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> ControlWorkspaceCloseResolution {
        closeResolution
    }

    func controlAddWorkspaceToGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        workspaceID: UUID,
        placement: WorkspaceGroupNewPlacement?,
        referenceWorkspaceID: UUID?
    ) -> ControlWorkspaceGroupAddResolution {
        addWorkspaceToGroupCall = (
            groupID: groupID,
            workspaceID: workspaceID,
            placement: placement,
            referenceWorkspaceID: referenceWorkspaceID
        )
        return addWorkspaceToGroupResolution
    }

    func controlWorkspaceRemoteTerminalSessionEnd(
        workspaceID: UUID, surfaceID: UUID, relayPort: Int?,
        sessionID: String?, lifecycleID: String?, lifecycleOnly: Bool
    ) -> ControlWorkspaceRemoteTerminalSessionEndResolution {
        terminalSessionEndCall = (workspaceID, surfaceID, relayPort, sessionID, lifecycleID, lifecycleOnly)
        return terminalSessionEndResolution
    }

    func controlWorkspaceRemoteTerminalSessionConnected(
        workspaceID: UUID,
        surfaceID: UUID,
        authority: ControlWorkspaceRemoteTerminalAuthority
    ) -> ControlWorkspaceRemoteTerminalSessionConnectedResolution {
        terminalSessionConnectedCall = (workspaceID, surfaceID, authority)
        return terminalSessionConnectedResolution
    }

    nonisolated func controlCurrentRemotePTYLifecycleOwner(
        sessionID: String,
        lifecycleID: String
    ) -> ControlRemotePTYLifecycleOwner? {
        currentRemotePTYLifecycleOwner
    }
}
