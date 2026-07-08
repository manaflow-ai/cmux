import Foundation
import CmuxSettings
@testable import CmuxControlSocket

// Benign default implementations of the non-window domain seams, so a test fake
// that conforms to the full `ControlCommandContext` umbrella only has to
// implement the domain it actually exercises. Each domain's own tests override
// the methods they drive; everything else returns an inert "nothing here"
// result. As domains land, add their defaults here (one block per domain).

extension ControlCommandContext {
    /// Test default for the worker-lane resolution hop primitive: run the
    /// body on the main actor (inline when the test is already there, else a
    /// synchronous dispatch), mirroring the app's `v2MainSync` semantics.
    /// Test fakes have no app topology, so there is no known-ref refresh —
    /// exactly like the pre-migration main-lane coordinator tests, whose
    /// refresh also lived app-side.
    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T {
        // The hop is synchronous: the calling thread blocks until `body`
        // returns, so handing the seam into the main-actor window cannot
        // outlive the call (the same contract as the app's `v2MainSync`).
        // Strict checking can't see that, hence the unsafe transfer.
        nonisolated(unsafe) let seam: any ControlCommandContext = self
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(seam) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { body(seam) }
        }
    }
}

extension ControlAppFocusContext {
    func controlSetAppFocusOverride(_ focused: Bool?) {}
    func controlSimulateAppActive() {}
}

extension ControlFeedContext {
    func controlFeedResolvePossibleSurface(workstreamID: String) -> Bool { false }
    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue] { [] }
}

extension ControlBillingContext {
    func controlBillingStatus() -> ControlCallResult {
        .ok(.object(["ok": .bool(false), "error": .string("unavailable")]))
    }

    func controlBillingCheckout(plan: String) -> ControlCallResult {
        .ok(.object(["ok": .bool(false), "error": .string("unavailable")]))
    }

    func controlBillingPortal() -> ControlCallResult {
        .ok(.object(["ok": .bool(false), "error": .string("unavailable")]))
    }
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

extension ControlCanvasContext {
    func controlCanvasInfo(routing: ControlRoutingSelectors) -> ControlCanvasInfoSnapshot? { nil }
    func controlCanvasSetMode(
        routing: ControlRoutingSelectors,
        mode: String
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasSetFrame(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        frame: ControlCanvasFrame
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasAlign(
        routing: ControlRoutingSelectors,
        command: ControlCanvasAlignCommand
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasReveal(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasToggleOverview(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasZoom(
        routing: ControlRoutingSelectors,
        direction: ControlCanvasZoomDirection
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasJoin(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        targetSurfaceID: UUID
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasBreak(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasSelectTab(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasSetViewport(
        routing: ControlRoutingSelectors,
        centerX: Double,
        centerY: Double,
        magnification: Double?
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
    func controlCanvasNewPane(
        routing: ControlRoutingSelectors,
        type: String
    ) -> ControlCanvasActionResolution { .tabManagerUnavailable }
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
        ControlWorkspaceGroupStrings(allChildrenAreAnchors: "", workspaceIsOtherGroupAnchor: "", invalidReferenceWorkspace: "invalid reference workspace")
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

    func controlAddWorkspaceToGroup(routing: ControlRoutingSelectors, groupID: UUID, workspaceID: UUID, placement: WorkspaceGroupNewPlacement?, referenceWorkspaceID: UUID?) -> ControlWorkspaceGroupAddResolution { .tabManagerUnavailable }

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

extension ControlWorkspaceContext {
    func controlWorkspaceStrings() -> ControlWorkspaceStrings {
        ControlWorkspaceStrings(
            closeProtected: "",
            reorderManyMissingOrder: "",
            reorderManyDuplicateWorkspace: "",
            reorderManyWorkspaceNotFound: "",
            reorderManyInvalidWorkspace: "",
            reorderManyTabManagerUnavailable: ""
        )
    }

    func controlWorkspaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { false }

    func controlWorkspaceList(routing: ControlRoutingSelectors) -> ControlWorkspaceListResolution {
        .tabManagerUnavailable
    }

    func controlWorkspaceCurrent(routing: ControlRoutingSelectors) -> ControlWorkspaceCurrentResolution {
        .tabManagerUnavailable
    }

    func controlWorkspaceCreate(params: [String: JSONValue]) -> ControlCallResult {
        .err(code: "unavailable", message: "", data: nil)
    }

    func controlSelectWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> ControlWorkspaceRoutedResolution { .tabManagerUnavailable }

    func controlCloseWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> ControlWorkspaceCloseResolution { .tabManagerUnavailable }

    func controlMoveWorkspaceToWindow(
        workspaceID: UUID,
        windowID: UUID,
        focusRequested: Bool
    ) -> ControlWorkspaceMoveToWindowResolution { .workspaceNotFound }

    func controlReorderWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        toIndex: Int?,
        beforeWorkspaceID: UUID?,
        afterWorkspaceID: UUID?,
        dryRun: Bool
    ) -> ControlWorkspaceReorderResolution { .notFound }

    func controlReorderWorkspacesMany(
        routing: ControlRoutingSelectors,
        workspaceIDs: [UUID],
        dryRun: Bool
    ) -> ControlWorkspaceReorderManyResolution { .tabManagerUnavailable }

    func controlSubmitWorkspacePrompt(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        message: String?
    ) -> ControlWorkspacePromptSubmitResolution { .tabManagerUnavailable }

    func controlRenameWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID,
        title: String
    ) -> ControlWorkspaceRoutedResolution { .tabManagerUnavailable }

    func controlSelectNextWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution {
        .tabManagerUnavailable
    }

    func controlSelectPreviousWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution {
        .tabManagerUnavailable
    }

    func controlSelectLastWorkspace(routing: ControlRoutingSelectors) -> ControlWorkspaceNavigationResolution {
        .tabManagerUnavailable
    }

    func controlEqualizeWorkspaceSplits(
        routing: ControlRoutingSelectors,
        orientationFilter: String?
    ) -> ControlWorkspaceEqualizeResolution { .tabManagerUnavailable }

    func controlConfigureWorkspaceRemote(
        params: [String: JSONValue],
        workspaceID: UUID
    ) -> ControlCallResult { .err(code: "unavailable", message: "", data: nil) }

    func controlDisconnectWorkspaceRemote(
        workspaceID: UUID,
        clearConfiguration: Bool
    ) -> ControlWorkspaceRemoteResolution { .notFound(workspaceID: workspaceID) }

    func controlReconnectWorkspaceRemote(
        workspaceID: UUID,
        surfaceID: UUID?
    ) -> ControlWorkspaceRemoteResolution {
        .notFound(workspaceID: workspaceID)
    }

    func controlWorkspaceRemoteForegroundAuthReady(
        workspaceID: UUID,
        foregroundAuthToken: String?
    ) -> ControlWorkspaceRemoteResolution { .notFound(workspaceID: workspaceID) }

    func controlWorkspaceRemoteStatus(workspaceID: UUID) -> ControlWorkspaceRemoteResolution {
        .notFound(workspaceID: workspaceID)
    }

    func controlResolveRemoteWorkspaceID(
        routing: ControlRoutingSelectors,
        requestedWorkspaceID: UUID?
    ) -> UUID? { requestedWorkspaceID }

    func controlWorkspaceRemotePTYAttachEnd(
        workspaceID: UUID,
        surfaceID: UUID,
        sessionID: String
    ) -> ControlWorkspaceRemotePTYAttachEndResolution { .notFound }

    func controlWorkspaceRemoteTerminalSessionEnd(
        workspaceID: UUID,
        surfaceID: UUID,
        relayPort: Int
    ) -> ControlWorkspaceRemoteTerminalSessionEndResolution { .notFound }
}

extension ControlSurfaceContext {
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { false }

    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot? { nil }
    func controlSurfaceCurrent(routing: ControlRoutingSelectors) -> ControlSurfaceCurrentSnapshot? { nil }
    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? { nil }

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution { .tabManagerUnavailable }

    func controlSurfaceRespawnStrings() -> ControlSurfaceRespawnStrings {
        ControlSurfaceRespawnStrings(
            invalidFocus: "",
            failed: "",
            surfaceNotFoundForID: "",
            tabManagerUnavailable: "",
            workspaceNotFound: "",
            noFocusedSurface: "",
            surfaceNotTerminal: ""
        )
    }

    func controlSurfaceSplit(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceSplitInputs
    ) -> ControlSurfaceSplitResolution { .tabManagerUnavailable }

    func controlSurfaceRespawn(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceRespawnInputs
    ) -> ControlSurfaceRespawnResolution { .tabManagerUnavailable }

    func controlSurfaceCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceCreateInputs
    ) -> ControlSurfaceCreateResolution { .tabManagerUnavailable }

    func controlSurfaceClose(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceCloseResolution { .tabManagerUnavailable }

    func controlSurfaceMove(params: [String: JSONValue]) -> ControlCallResult {
        .err(code: "internal_error", message: "", data: nil)
    }

    func controlSurfaceReorder(
        surfaceID: UUID,
        inputs: ControlSurfaceReorderInputs,
        requestedFocus: Bool
    ) -> ControlSurfaceReorderResolution { .surfaceNotFound(surfaceID) }

    func controlSurfaceRefresh(
        routing: ControlRoutingSelectors
    ) -> ControlSurfaceRefreshResolution { .tabManagerUnavailable }

    func controlSurfaceClearHistory(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool
    ) -> ControlSurfaceClearHistoryResolution { .tabManagerUnavailable }

    func controlSurfaceTriggerFlash(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceTriggerFlashResolution { .tabManagerUnavailable }

    nonisolated func controlSurfaceInputStrings() -> ControlSurfaceInputStrings {
        ControlSurfaceInputStrings(inputQueueFull: "", surfaceUnavailable: "", processExited: "")
    }

    func controlSurfaceSendText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        text: String
    ) -> ControlSurfaceSendResolution { .tabManagerUnavailable }

    func controlSurfaceSendKey(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        key: String
    ) -> ControlSurfaceSendResolution { .tabManagerUnavailable }

    func controlSurfaceResumeSet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        inputs: ControlSurfaceResumeSetInputs
    ) -> ControlSurfaceResumeResolution { .surfaceNotFound }

    func controlSurfaceResumeGet(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool
    ) -> ControlSurfaceResumeResolution { .surfaceNotFound }

    func controlSurfaceResumeClear(
        routing: ControlRoutingSelectors,
        explicitTargetID: UUID?,
        hasResolvedWindowID: Bool,
        expectedCheckpointID: String?,
        expectedSource: String?
    ) -> ControlSurfaceResumeResolution { .surfaceNotFound }

    nonisolated func controlSurfaceParseShellActivityState(_ rawState: String) -> String? { nil }
    nonisolated func controlSurfaceParsePortScanKickReason(_ rawReason: String) -> String? { nil }

    func controlSurfaceReportTTY(workspaceID: UUID, requestedSurfaceID: UUID?, ttyName: String)
        -> ControlSurfaceReportTTYResolution { .workspaceNotFound }
    func controlSurfaceReportPWD(workspaceID: UUID, requestedSurfaceID: UUID?, path: String)
        -> ControlSurfaceReportPWDResolution { .workspaceNotFound }

    func controlSurfaceReportShellState(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        stateRawValue: String
    ) -> ControlSurfaceReportShellStateResolution { .pending }

    func controlSurfacePortsKick(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        reasonRawValue: String
    ) -> ControlSurfacePortsKickResolution { .workspaceNotFound }

    func controlDebugTerminals() -> JSONValue? { nil }
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
    func controlMobileTerminalPaste(params: [String: JSONValue]) -> ControlCallResult { mobileHostStubResult }
    func controlMobileChatSessionsDump() -> ControlCallResult { mobileHostStubResult }
}
