import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the browser-panel (v1) and sidebar seams, so a test fake that conforms to the full
// `ControlCommandContext` umbrella only has to implement the domain it
// actually exercises (the per-domain companion to the shared
// `ControlCommandContextTestStubs.swift`).

extension ControlBrowserContext {
    func controlBrowserRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { false }

    func controlBrowserOpenSplit(
        routing: ControlRoutingSelectors,
        rawURLString: String?,
        respectExternalOpenRules: Bool,
        diffViewerToken: String?,
        diffViewerFiles: [JSONValue]?,
        explicitSourceSurfaceID: UUID?,
        requestedFocus: Bool,
        showOmnibar: Bool,
        transparentBackground: Bool,
        bypassRemoteProxyParam: Bool?
    ) -> ControlBrowserOpenSplitResolution { .tabManagerUnavailable }

    func controlBrowserReactGrabToggle(
        routing: ControlRoutingSelectors,
        browserSurfaceID: UUID?,
        returnSurfaceID: UUID?
    ) -> ControlBrowserActionResolution { .noBrowserSurface }

    func controlBrowserDevToolsToggle(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool
    ) -> ControlBrowserActionResolution { .noBrowserSurface }

    func controlBrowserConsoleShow(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool
    ) -> ControlBrowserActionResolution { .noBrowserSurface }

    func controlBrowserFocusModeSet(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool,
        intent: ControlBrowserFocusModeIntent
    ) -> ControlBrowserActionResolution { .noBrowserSurface }

    func controlBrowserZoomSet(
        routing: ControlRoutingSelectors,
        explicitSurfaceID: UUID?,
        surfaceWasSupplied: Bool,
        direction: ControlBrowserZoomDirection
    ) -> ControlBrowserActionResolution { .noBrowserSurface }

    func controlBrowserClearDefaultHistory() {}

    func controlBrowserCurrentURL(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserURLResolution { .notFound }

    func controlBrowserFocusWebView(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserFocusWebViewResolution { .notFound }

    func controlBrowserIsWebViewFocused(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlBrowserIsWebViewFocusedResolution {
        ControlBrowserIsWebViewFocusedResolution(focused: false)
    }

    func controlBrowserCookiesGet(
        params: [String: JSONValue],
        nameFilter: String?,
        domainFilter: String?,
        pathFilter: String?
    ) -> ControlBrowserCookiesGetResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserCookiesSet(
        params: [String: JSONValue],
        cookieRows: [JSONValue]
    ) -> ControlBrowserCookiesSetResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserCookiesClear(
        params: [String: JSONValue],
        nameFilter: String?,
        domainFilter: String?,
        clearAll: Bool
    ) -> ControlBrowserCookiesClearResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserStorageGet(
        params: [String: JSONValue],
        key: String?
    ) -> ControlBrowserStorageGetResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserStorageSet(
        params: [String: JSONValue],
        key: String,
        value: JSONValue
    ) -> ControlBrowserStorageSetResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserStorageClear(
        params: [String: JSONValue]
    ) -> ControlBrowserStorageClearResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserRecordUnsupportedNetworkRequest(
        surfaceID: UUID,
        action: String,
        params: [String: JSONValue]
    ) {}

    func controlBrowserUnsupportedNetworkRequests(surfaceID: UUID) -> [JSONValue] { [] }

    func controlBrowserAddInitScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddInitScriptResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserAddScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddScriptResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserAddStyle(
        params: [String: JSONValue],
        css: String
    ) -> ControlBrowserAddStyleResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserDialogRespond(
        params: [String: JSONValue],
        accept: Bool,
        text: String?
    ) -> ControlBrowserDialogRespondResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserImportDialog(
        params: [String: JSONValue]
    ) -> ControlBrowserImportDialogResolution { .opened(scopeRawValue: nil) }

    func controlBrowserGetTitle(
        params: [String: JSONValue]
    ) -> ControlBrowserGetTitleResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserFrameSelect(
        params: [String: JSONValue],
        rawSelector: String
    ) -> ControlBrowserFrameSelectResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserFrameMain(
        params: [String: JSONValue]
    ) -> ControlBrowserFrameMainResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserScreenshot(
        params: [String: JSONValue]
    ) -> ControlBrowserScreenshotResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserConsoleList(
        params: [String: JSONValue],
        clear: Bool
    ) -> ControlBrowserConsoleListResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserErrorsList(
        params: [String: JSONValue],
        clear: Bool
    ) -> ControlBrowserErrorsListResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserStateSave(
        params: [String: JSONValue],
        path: String
    ) -> ControlBrowserStateSaveResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserStateLoad(
        params: [String: JSONValue],
        path: String
    ) -> ControlBrowserStateLoadResolution { .failed(.tabManagerUnavailable) }

    func controlBrowserTabList(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabListResolution { .tabManagerUnavailable }

    func controlBrowserTabNew(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors,
        rawURLString: String?
    ) -> ControlBrowserTabNewResolution { .tabManagerUnavailable }

    func controlBrowserTabSwitch(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabSwitchResolution { .tabManagerUnavailable }

    func controlBrowserTabClose(
        params: [String: JSONValue],
        routing: ControlRoutingSelectors
    ) -> ControlBrowserTabCloseResolution { .tabManagerUnavailable }
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

    func controlSidebarScheduleScopedDirectoryUpdate(scope: ControlSidebarPanelScope, directory: String, displayLabel: String?) {}

    func controlSidebarUpdateDirectory(tabArg: String?, panelArg: String?, directory: String, displayLabel: String?) -> ControlSidebarPanelWriteResolution {
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
    ) -> ControlSidebarPaneSplitResolution { .failed }

    func controlSidebarNewSurface(isBrowser: Bool, paneArg: String?, url: URL?) -> ControlSidebarNewSurfaceResolution {
        .noTabSelected
    }

    func controlSidebarCloseSurface(surfaceArg: String?) -> ControlSidebarCloseSurfaceResolution { .noTabSelected }

    func controlSidebarReloadConfig() {}
    func controlSidebarRefreshSurfaces() -> Int { 0 }
    func controlSidebarSurfaceHealth(tabArg: String) -> [ControlSidebarSurfaceHealthRow]? { nil }
}
