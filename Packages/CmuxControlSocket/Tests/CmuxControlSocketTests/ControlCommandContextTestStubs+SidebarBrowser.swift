import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the browser, browser-panel (v1), and
// sidebar seams, so a test fake that conforms to the full
// `ControlCommandContext` umbrella only has to implement the domain it
// actually exercises (the per-domain companion to the shared
// `ControlCommandContextTestStubs.swift`).

extension ControlBrowserContext {
    func controlBrowserIsAvailabilityDisabled() -> Bool { false }
    func controlBrowserIsAvailabilityEnabled() -> Bool { false }
    func controlBrowserIsDiffViewerURL(_ urlString: String?) -> Bool { false }

    func controlBrowserDisabledExternalOpen(
        rawURL: String?,
        routing: ControlRoutingSelectors
    ) -> ControlSurfaceBrowserDisabledOutcome { .noURL }

    func controlBrowserRegisterDiffViewer(
        urlString: String?,
        token: String?,
        files: JSONValue?
    ) -> ControlBrowserDiffViewerRegistration { .notApplicable }

    func controlBrowserOpenSplit(
        routing: ControlRoutingSelectors,
        inputs: ControlBrowserOpenSplitInputs
    ) -> ControlBrowserOpenSplitResolution { .workspaceNotFound }

    func controlBrowserNavigate(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        urlString: String
    ) -> ControlBrowserNavResolution { .notFoundOrNotBrowser }

    func controlBrowserNavAction(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        action: ControlBrowserNavAction
    ) -> ControlBrowserNavResolution { .notFoundOrNotBrowser }

    func controlBrowserReactGrabToggle(
        routing: ControlRoutingSelectors,
        browserSurfaceID: UUID?,
        returnSurfaceID: UUID?
    ) -> ControlBrowserReactGrabResolution { .notFound }

    func controlBrowserDevToolsToggle(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget
    ) -> ControlBrowserHandledResolution { .notFound }

    func controlBrowserConsoleShow(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget
    ) -> ControlBrowserHandledResolution { .notFound }

    func controlBrowserFocusModeSet(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget,
        action: ControlBrowserFocusModeAction
    ) -> ControlBrowserHandledResolution { .notFound }

    func controlBrowserZoomSet(
        routing: ControlRoutingSelectors,
        target: ControlBrowserFocusedActionTarget,
        direction: ControlBrowserZoomDirection
    ) -> ControlBrowserHandledResolution { .notFound }

    func controlBrowserClearDefaultProfileHistory() {}

    func controlBrowserCurrentURL(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserURLResolution { .notFoundOrNotBrowser }

    func controlBrowserFocusWebView(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserFocusWebViewResolution { .notFoundOrNotBrowser }

    func controlBrowserIsWebViewFocused(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> Bool { false }

    func controlBrowserRunScript(
        target: ControlBrowserSurfaceTarget,
        script: String,
        timeout: Double,
        mode: ControlBrowserScriptMode
    ) -> ControlBrowserScriptResolution { .failure(.tabManagerUnavailable) }

    func controlBrowserCookiesGet(
        target: ControlBrowserSurfaceTarget
    ) -> ControlBrowserCookiesGetResolution { .failure(.tabManagerUnavailable) }

    func controlBrowserCookiesSet(
        target: ControlBrowserSurfaceTarget,
        rows: [JSONValue]
    ) -> ControlBrowserCookiesSetResolution { .failure(.tabManagerUnavailable) }

    func controlBrowserCookiesClear(
        target: ControlBrowserSurfaceTarget,
        name: String?,
        domain: String?,
        hasAllParam: Bool
    ) -> ControlBrowserCookiesClearResolution { .failure(.tabManagerUnavailable) }

    func controlBrowserStateCapture(
        target: ControlBrowserSurfaceTarget,
        storageScript: String
    ) -> ControlBrowserStateCaptureResolution { .failure(.tabManagerUnavailable) }

    func controlBrowserStateApply(
        target: ControlBrowserSurfaceTarget,
        frameSelector: String?,
        navigateToURLString: String?,
        cookieRows: [JSONValue],
        storageScript: String?
    ) -> ControlBrowserStateApplyResolution { .failure(.tabManagerUnavailable) }

    func controlBrowserTabList(routing: ControlRoutingSelectors) -> ControlBrowserTabListSnapshot? { nil }

    func controlBrowserTabNew(
        routing: ControlRoutingSelectors,
        urlString: String?,
        explicitPaneID: UUID?,
        paneFromSurfaceID: UUID?
    ) -> ControlBrowserTabNewResolution { .workspaceNotFound }

    func controlBrowserTabSwitch(
        routing: ControlRoutingSelectors,
        explicitID: UUID?,
        index: Int?,
        surfaceID: UUID?
    ) -> ControlBrowserTabSwitchResolution { .workspaceNotFound }

    func controlBrowserTabClose(
        routing: ControlRoutingSelectors,
        explicitID: UUID?,
        index: Int?,
        surfaceID: UUID?
    ) -> ControlBrowserTabCloseResolution { .workspaceNotFound }

    func controlBrowserRecordUnsupportedRequest(surfaceID: UUID, request: JSONValue) {}
    func controlBrowserUnsupportedRequests(surfaceID: UUID) -> [JSONValue] { [] }

    func controlBrowserImportResolveDestinationProfile(
        query: String,
        createIfMissing: Bool
    ) -> ControlBrowserImportProfileResolution { .noMatch }

    func controlBrowserImportPresentDialog(
        scope: ControlBrowserImportScope?,
        destinationProfileID: UUID?
    ) {}
}

extension ControlBrowserPanelContext {
    func controlBrowserPanelTabManagerAvailable() -> Bool { false }
    func controlBrowserPanelAvailabilityEnabled() -> Bool { false }
    func controlBrowserPanelOpenURLExternally(_ url: URL) -> Bool { false }
    func controlBrowserPanelOpen(url: URL?) -> UUID? { nil }
    func controlBrowserPanelNavigate(panelID: UUID, urlString: String) -> Bool { false }
    func controlBrowserPanelGoBack(panelID: UUID) -> Bool { false }
    func controlBrowserPanelGoForward(panelID: UUID) -> Bool { false }
    func controlBrowserPanelReload(panelID: UUID) -> Bool { false }
    func controlBrowserPanelCurrentURLString(panelID: UUID) -> String? { nil }

    func controlBrowserPanelFocusWebView(panelID: UUID) -> ControlBrowserPanelFocusWebViewResolution {
        .panelNotFound
    }

    func controlBrowserPanelIsWebViewFocused(panelID: UUID) -> ControlBrowserPanelWebViewFocusState {
        .panelNotFound
    }
}

extension ControlSidebarContext {
    func controlSidebarTabManagerAvailable() -> Bool { false }

    func controlSidebarScheduleStatusUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: ControlSidebarMetadataFormat,
        panelID: UUID?,
        pid: Int32?
    ) {}

    func controlSidebarScheduleStatusClear(target: ControlSidebarTabTarget, key: String) {}

    func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?
    ) {}

    func controlSidebarParseAgentLifecycle(_ raw: String) -> String? { nil }

    func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool { false }

    func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?
    ) {}

    func controlSidebarSetAgentHibernation(enabled: Bool) {}

    func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool
    ) {}

    func controlSidebarScheduleMetadataBlockUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        markdown: String,
        priority: Int
    ) {}

    func controlSidebarStatusEntries(tabArg: String?) -> [ControlSidebarStatusEntrySnapshot]? { nil }
    func controlSidebarMetadataBlocks(tabArg: String?) -> [ControlSidebarMetadataBlockSnapshot]? { nil }

    func controlSidebarClearMetadataBlock(tabArg: String?, key: String) -> ControlSidebarClearMetaBlockResolution {
        .tabNotFound
    }

    func controlSidebarIsValidLogLevel(_ raw: String) -> Bool { false }

    func controlSidebarAppendLog(
        tabArg: String?,
        message: String,
        levelRawValue: String,
        source: String?
    ) -> Bool { false }

    func controlSidebarClearLog(tabArg: String?) -> Bool { false }
    func controlSidebarLogEntries(tabArg: String?) -> [ControlSidebarLogEntrySnapshot]? { nil }
    func controlSidebarSetProgress(tabArg: String?, value: Double, label: String?) -> Bool { false }
    func controlSidebarClearProgress(tabArg: String?) -> Bool { false }

    func controlSidebarScheduleScopedGitBranchUpdate(
        scope: ControlSidebarPanelScope,
        branch: String,
        isDirty: Bool?
    ) {}

    func controlSidebarUpdateGitBranch(tabArg: String?, branch: String, isDirty: Bool?) -> Bool { false }
    func controlSidebarScheduleScopedGitBranchClear(scope: ControlSidebarPanelScope) {}
    func controlSidebarClearGitBranch(tabArg: String?) -> Bool { false }

    func controlSidebarIsValidPullRequestState(_ raw: String) -> Bool { false }

    func controlSidebarSchedulePanelPullRequestUpdate(
        target: ControlSidebarPanelMutationTarget,
        number: Int,
        label: String,
        url: URL,
        statusRawValue: String,
        branch: String?
    ) {}

    func controlSidebarSchedulePanelPullRequestClear(target: ControlSidebarPanelMutationTarget) {}

    func controlSidebarSchedulePanelPullRequestAction(
        target: ControlSidebarPanelMutationTarget,
        action: String,
        actionTarget: String?
    ) {}

    func controlSidebarSetPorts(tabArg: String?, panelArg: String?, ports: [Int]) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    func controlSidebarClearPorts(tabArg: String?, panelArg: String?) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    func controlSidebarScheduleScopedDirectoryUpdate(scope: ControlSidebarPanelScope, directory: String) {}

    func controlSidebarUpdateDirectory(tabArg: String?, panelArg: String?, directory: String) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    func controlSidebarScheduleScopedShellState(scope: ControlSidebarPanelScope, stateRawValue: String) {}

    func controlSidebarUpdateShellState(tabArg: String?, panelArg: String?, stateRawValue: String) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    func controlSidebarScheduleScopedTTY(scope: ControlSidebarPanelScope, ttyName: String) {}

    func controlSidebarReportTTY(tabArg: String?, panelArg: String?, ttyName: String) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    func controlSidebarScheduleScopedPortsKick(scope: ControlSidebarPanelScope, reasonRawValue: String) {}

    func controlSidebarPortsKick(tabArg: String?, panelArg: String?, reasonRawValue: String) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    func controlSidebarStateSnapshot(tabArg: String?) -> ControlSidebarStateSnapshot? { nil }
    func controlSidebarReset(tabArg: String?) -> Bool { false }

    func controlSidebarApplyRightSidebarRemoteCommand(tokens: [String]) -> ControlSidebarRightSidebarResolution {
        .failure(message: "")
    }

    func controlSidebarPaneList() -> ControlSidebarPaneListSnapshot? { nil }

    func controlSidebarPaneSurfaces(paneArg: String?) -> ControlSidebarPaneSurfacesResolution { .noTabSelected }

    func controlSidebarFocusPane(paneArg: String) -> Bool { false }
    func controlSidebarFocusSurfaceByPanel(panelID: UUID) -> Bool { false }
    func controlSidebarRefreshKnownRefs() {}

    func controlSidebarSplitOffSurface(surfaceID: UUID, directionRawValue: String) -> ControlSidebarSplitOffOutcome {
        .error(message: "")
    }

    func controlSidebarDragSurfaceToSplit(
        surfaceArg: String,
        orientationIsHorizontal: Bool,
        insertFirst: Bool
    ) -> ControlSidebarDragToSplitResolution { .noTabSelected }

    func controlSidebarCreatePaneSplit(
        isBrowser: Bool,
        orientationIsHorizontal: Bool,
        insertFirst: Bool,
        url: URL?
    ) -> UUID? { nil }

    func controlSidebarNewSurface(isBrowser: Bool, paneArg: String?, url: URL?) -> ControlSidebarNewSurfaceResolution {
        .noTabSelected
    }

    func controlSidebarCloseSurface(surfaceArg: String?) -> ControlSidebarCloseSurfaceResolution { .noTabSelected }

    func controlSidebarReloadConfig() {}
    func controlSidebarRefreshSurfaces() -> Int { 0 }
    func controlSidebarSurfaceHealth(tabArg: String) -> [ControlSidebarSurfaceHealthRow]? { nil }
}
