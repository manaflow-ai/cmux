import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the non-window domain seams, so a test fake
// that conforms to the full `ControlCommandContext` umbrella only has to
// implement the domain it actually exercises. Each domain's own tests override
// the methods they drive; everything else returns an inert "nothing here"
// result. As domains land, add their defaults here (one block per domain).

extension ControlAppFocusContext {
    func controlSetAppFocusOverride(_ focused: Bool?) {}
    func controlSimulateAppActive() {}
}

extension ControlFeedContext {
    func controlFeedResolvePossibleSurface(workstreamID: String) -> Bool { false }
    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue] { [] }
}

extension ControlPaneContext {
    func controlPaneList(routing: ControlRoutingSelectors) -> ControlPaneListSnapshot? { nil }
    func controlPaneRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { false }
    func controlPaneFocus(
        routing: ControlRoutingSelectors,
        paneID: UUID
    ) -> ControlPaneFocusResolution { .tabManagerUnavailable }
    func controlPaneSurfaces(
        routing: ControlRoutingSelectors,
        paneID: UUID?
    ) -> ControlPaneSurfacesSnapshot? { nil }
    func controlPaneCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution { .tabManagerUnavailable }
    func controlPaneResize(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneResizeInputs
    ) -> ControlPaneResizeResolution { .tabManagerUnavailable }
    func controlPaneSwap(
        sourcePaneID: UUID,
        targetPaneID: UUID,
        requestedFocus: Bool
    ) -> ControlPaneSwapResolution { .sourcePaneNotFound(sourcePaneID) }
    func controlPaneBreak(
        routing: ControlRoutingSelectors,
        paneID: UUID?,
        surfaceID: UUID?,
        requestedFocus: Bool
    ) -> ControlPaneBreakResolution { .tabManagerUnavailable }
    func controlPaneJoin(
        targetPaneID: UUID,
        surfaceID: UUID?,
        sourcePaneID: UUID?,
        hasFocusParam: Bool,
        focus: Bool
    ) -> ControlPaneJoinResolution { .missingSurface }
    func controlPaneLast(routing: ControlRoutingSelectors) -> ControlPaneLastResolution { .tabManagerUnavailable }
}

extension ControlNotificationContext {
    func controlNotificationCreate(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationCreateResolution { .tabManagerUnavailable }

    func controlNotificationCreateForSurface(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationTargetedDeliveryResolution { .tabManagerUnavailable }

    func controlNotificationCreateForTarget(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        surfaceID: UUID,
        title: String,
        subtitle: String,
        body: String
    ) -> ControlNotificationTargetedDeliveryResolution { .tabManagerUnavailable }

    func controlNotificationList() -> [ControlNotificationSnapshot] { [] }
    func controlNotificationDismissAllRead() -> Int { 0 }
    func controlNotificationDismiss(id: UUID) -> ControlNotificationDismissResolution { .notFound }
    func controlNotificationMarkRead(id: UUID) -> ControlNotificationMarkReadResolution { .notFound }
    func controlNotificationMarkRead(
        workspaceID: UUID,
        surfaceID: UUID?,
        hasSurfaceSelector: Bool
    ) -> Int { 0 }
    func controlNotificationMarkReadAll() -> Int { 0 }
    func controlNotificationOpen(id: UUID) -> ControlNotificationOpenResolution { .notificationNotFound }
    func controlNotificationJumpToUnread() -> ControlNotificationSnapshot? { nil }
    func controlNotificationClear() {}

    var notificationStrings: ControlNotificationStrings {
        ControlNotificationStrings(
            dismissSelectorRequired: "",
            idRequired: "",
            notFound: "",
            markReadSelectorRequired: "",
            surfaceIDInvalid: "",
            surfaceIDRequiresWorkspace: "",
            targetNotFound: ""
        )
    }
}

extension ControlWorkspaceGroupContext {
    func controlWorkspaceGroupStrings() -> ControlWorkspaceGroupStrings {
        ControlWorkspaceGroupStrings(allChildrenAreAnchors: "", workspaceIsOtherGroupAnchor: "")
    }

    func controlWorkspaceGroupList(
        routing: ControlRoutingSelectors
    ) -> ControlWorkspaceGroupListResolution { .tabManagerUnavailable }

    func controlCreateWorkspaceGroup(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        childWorkspaceIDs: [UUID],
        childrenExplicit: Bool
    ) -> ControlWorkspaceGroupCreateResolution { .tabManagerUnavailable }

    func controlUngroupWorkspaceGroup(routing: ControlRoutingSelectors, groupID: UUID) -> Bool? { nil }
    func controlDeleteWorkspaceGroup(routing: ControlRoutingSelectors, groupID: UUID) -> Int? { nil }
    func controlRenameWorkspaceGroup(routing: ControlRoutingSelectors, groupID: UUID, name: String) -> Bool? { nil }
    func controlSetWorkspaceGroupCollapsed(routing: ControlRoutingSelectors, groupID: UUID, isCollapsed: Bool) -> Bool? { nil }
    func controlSetWorkspaceGroupPinned(routing: ControlRoutingSelectors, groupID: UUID, isPinned: Bool) -> Bool? { nil }

    func controlAddWorkspaceToGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        workspaceID: UUID
    ) -> ControlWorkspaceGroupAddResolution { .tabManagerUnavailable }

    func controlRemoveWorkspaceFromGroup(routing: ControlRoutingSelectors, workspaceID: UUID) -> Bool? { nil }
    func controlSetWorkspaceGroupAnchor(routing: ControlRoutingSelectors, groupID: UUID, workspaceID: UUID) -> Bool? { nil }

    func controlCreateWorkspaceInGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        placementRaw: String?
    ) -> ControlWorkspaceGroupNewWorkspaceResolution { .tabManagerUnavailable }

    func controlSetWorkspaceGroupColor(routing: ControlRoutingSelectors, groupID: UUID, hex: String?) -> Bool? { nil }
    func controlSetWorkspaceGroupIcon(routing: ControlRoutingSelectors, groupID: UUID, symbol: String?) -> (found: Bool, storedSymbol: String?)? { nil }

    func controlMoveWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        toIndex: Int?,
        beforeGroupID: UUID?,
        afterGroupID: UUID?
    ) -> Bool? { nil }

    func controlFocusWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> ControlWorkspaceGroupFocusResolution { .tabManagerUnavailable }
}

extension ControlMobileHostContext {
    private var mobileHostStubResult: ControlCallResult {
        .err(code: "unavailable", message: "", data: nil)
    }

    func controlMobileHostStatus(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
    func controlMobileWorkspaceList(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
    func controlMobileTerminalCreate(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
    func controlMobileTerminalInput(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
    func controlMobileTerminalReplay(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
    func controlMobileTerminalViewport(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
    func controlMobileTerminalScroll(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
    func controlMobileTerminalMouse(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
}
