import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the browser-panel (v1) and sidebar seams, so a test fake that conforms to the full
// `ControlCommandContext` umbrella only has to implement the domain it
// actually exercises (the per-domain companion to the shared
// `ControlCommandContextTestStubs.swift`).

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

    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState? { nil }

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
    ) -> ControlSidebarPaneSplitResolution { .failed }

    func controlSidebarNewSurface(isBrowser: Bool, paneArg: String?, url: URL?) -> ControlSidebarNewSurfaceResolution {
        .noTabSelected
    }

    func controlSidebarCloseSurface(surfaceArg: String?) -> ControlSidebarCloseSurfaceResolution { .noTabSelected }

    func controlSidebarReloadConfig() {}
    func controlSidebarRefreshSurfaces() -> Int { 0 }
    func controlSidebarSurfaceHealth(tabArg: String) -> [ControlSidebarSurfaceHealthRow]? { nil }
}
