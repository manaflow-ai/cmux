import Foundation
@testable import CmuxControlSocket

extension ControlNotificationContext {
    func controlNotificationCreateForCaller(
        preferredWorkspaceID: UUID?,
        preferredSurfaceID: UUID?,
        callerTTY: String?,
        preferTTY: Bool,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationCallerDeliveryResolution { .tabManagerUnavailable }

    func controlNotifyCurrentV1(args: String) -> String { "" }
    func controlNotifySurfaceV1(args: String) -> String { "" }
    func controlNotifyTargetV1(args: String) -> String { "" }
    func controlNotifyTargetQueuedV1(args: String) -> String { "" }
    func controlNotificationsListV1() -> String { "" }
    func controlNotificationsClearV1(args: String) -> String { "" }
}

extension ControlWorkspaceContext {
    func controlWorkspaceAutoNamingEnabled() -> Bool { false }

    func controlWorkspaceAutoTitleProbe(
        routing: ControlRoutingSelectors,
        hasWorkspaceID: Bool,
        workspaceID: UUID?
    ) -> ControlWorkspaceAutoTitleProbe {
        ControlWorkspaceAutoTitleProbe(
            enabled: false,
            summarizerAgentSlug: nil,
            includeUserOwned: false,
            userOwned: nil
        )
    }

    func controlRecordAutoNamingFailure(rawCategory: String, agent: String) {}

    func controlApplyWorkspaceAutoTitle(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        title: String,
        panelID: UUID?,
        panelOnlyIfMultiple: Bool
    ) -> ControlWorkspaceSetAutoTitleResolution { .tabManagerUnavailable }

    func controlWorkspaceEnv(routing: ControlRoutingSelectors) -> ControlWorkspaceEnvResolution {
        .tabManagerUnavailable
    }

    func controlListWorkspacesV1() -> String { "" }
    func controlCurrentWorkspaceV1() -> String { "" }
    func controlNewWorkspaceV1(args: String) -> String { "" }
    func controlNewSplitV1(args: String) -> String { "" }
    func controlCloseWorkspaceV1(arg: String) -> String { "" }
    func controlSelectWorkspaceV1(arg: String) -> String { "" }

    func controlWorkspaceColorPalette() -> [ControlWorkspaceColorPaletteEntry] { [] }
    func controlWorkspaceActionResolveTarget(
        routing: ControlRoutingSelectors,
        requestedWorkspaceID: UUID?
    ) -> ControlWorkspaceActionTarget? { nil }
    func controlWorkspaceActionSetPinned(workspaceID: UUID, pinned: Bool) {}
    func controlWorkspaceActionSetCustomTitle(workspaceID: UUID, title: String) {}
    func controlWorkspaceActionClearCustomTitle(workspaceID: UUID) -> String { "" }
    func controlWorkspaceActionSetCustomDescription(workspaceID: UUID, description: String) -> String? { nil }
    func controlWorkspaceActionClearCustomDescription(workspaceID: UUID) {}
    func controlWorkspaceActionReorder(
        workspaceID: UUID,
        direction: ControlWorkspaceActionReorderDirection
    ) -> ControlWorkspaceActionReorderOutcome { .notFound }
    func controlWorkspaceActionMoveTop(workspaceID: UUID) -> Int? { nil }
    func controlWorkspaceActionClose(
        workspaceID: UUID,
        scope: ControlWorkspaceActionCloseScope
    ) -> ControlWorkspaceActionCloseOutcome { .notFound }
    func controlWorkspaceActionMarkRead(workspaceID: UUID) {}
    func controlWorkspaceActionMarkUnread(workspaceID: UUID) {}
    func controlWorkspaceActionSetTabColor(workspaceID: UUID, hex: String?) {}
}

extension ControlSurfaceContext {
    func controlSurfaceMoveLocateSource(surfaceID: UUID) -> ControlSurfaceMoveSourceResolution { .surfaceNotFound }

    func controlSurfaceMoveLocateAnchor(surfaceID: UUID) -> ControlSurfaceMoveAnchorSnapshot? { nil }

    func controlSurfaceMoveLocatePane(paneID: UUID) -> ControlSurfaceMovePaneSnapshot? { nil }

    func controlSurfaceMoveLocateWorkspace(workspaceID: UUID) -> ControlSurfaceMoveWorkspaceSnapshot? { nil }

    func controlSurfaceMoveLocateWindow(windowID: UUID) -> ControlSurfaceMoveWindowResolution { .windowNotFound }

    func controlSurfaceMovePerformMove(
        workspaceID: UUID,
        surfaceID: UUID,
        destinationPaneID: UUID,
        index: Int?,
        requestedFocus: Bool
    ) -> Bool { false }

    func controlSurfaceMovePerformTransfer(
        sourceWorkspaceID: UUID,
        sourcePaneID: UUID?,
        sourceIndex: Int?,
        targetWorkspaceID: UUID,
        targetWindowID: UUID,
        surfaceID: UUID,
        destinationPaneID: UUID,
        index: Int?,
        requestedFocus: Bool
    ) -> ControlSurfaceMoveTransferOutcome { .detachFailed }

    func controlSurfaceListV1(tabArg: String) -> String { "" }
    func controlSurfaceFocusV1(arg: String) -> String { "" }
    func controlSurfaceSendInputV1(text: String) -> String { "" }
    func controlSurfaceSendKeyV1(keyName: String) -> String { "" }
    func controlSurfaceSendInputToSurfaceV1(args: String) -> String { "" }
    func controlSurfaceSendKeyToSurfaceV1(args: String) -> String { "" }
    #if DEBUG
    func controlSurfaceSendInputToWorkspaceV1(args: String) -> String { "" }
    #endif
    func controlSurfaceReadScreenV1(args: String) -> String { "" }
}
