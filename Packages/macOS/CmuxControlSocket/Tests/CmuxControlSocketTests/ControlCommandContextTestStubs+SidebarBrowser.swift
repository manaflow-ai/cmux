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
    /// Test default for the worker-lane hop primitive: run the body on the
    /// main actor (inline when the test is already there, else a synchronous
    /// dispatch), mirroring the app's `v2MainSync` semantics.
    nonisolated func controlSidebarOnMain<T: Sendable>(
        _ body: @MainActor (any ControlSidebarContext) -> T
    ) -> T {
        // The hop is synchronous: the calling thread blocks until `body`
        // returns, so handing the seam into the main-actor window cannot
        // outlive the call (the same contract as the app's `v2MainSync`).
        // Strict checking can't see that, hence the unsafe transfer.
        nonisolated(unsafe) let seam: any ControlSidebarContext = self
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(seam) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { body(seam) }
        }
    }

    func controlSidebarTabManagerAvailable() -> Bool { false }

    nonisolated func controlSidebarScheduleStatusUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: ControlSidebarMetadataFormat,
        panelID: UUID?,
        pid: Int32?,
        dynamicAgentRowKey: Bool
    ) {}

    nonisolated func controlSidebarScheduleStatusClear(target: ControlSidebarTabTarget, key: String) {}

    nonisolated func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?
    ) {}

    nonisolated func controlSidebarParseAgentLifecycle(_ raw: String) -> String? { nil }

    nonisolated func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool { false }

    nonisolated func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?
    ) {}

    nonisolated func controlSidebarSetAgentHibernation(enabled: Bool) {}

    nonisolated func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool
    ) {}

    nonisolated func controlSidebarScheduleMetadataBlockUpsert(
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

    nonisolated func controlSidebarIsValidLogLevel(_ raw: String) -> Bool { false }

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

    nonisolated func controlSidebarScheduleScopedGitBranchUpdate(
        scope: ControlSidebarPanelScope,
        branch: String,
        isDirty: Bool?
    ) {}

    func controlSidebarUpdateGitBranch(tabArg: String?, branch: String, isDirty: Bool?) -> Bool { false }
    nonisolated func controlSidebarScheduleScopedGitBranchClear(scope: ControlSidebarPanelScope) {}
    func controlSidebarClearGitBranch(tabArg: String?) -> Bool { false }

    nonisolated func controlSidebarIsValidPullRequestState(_ raw: String) -> Bool { false }

    nonisolated func controlSidebarSchedulePanelPullRequestUpdate(
        target: ControlSidebarPanelMutationTarget,
        number: Int,
        label: String,
        url: URL,
        statusRawValue: String,
        branch: String?
    ) {}

    nonisolated func controlSidebarSchedulePanelPullRequestClear(target: ControlSidebarPanelMutationTarget) {}

    nonisolated func controlSidebarSchedulePanelPullRequestAction(
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

    nonisolated func controlSidebarScheduleScopedDirectoryUpdate(scope: ControlSidebarPanelScope, directory: String, displayLabel: String?) {}

    func controlSidebarUpdateDirectory(tabArg: String?, panelArg: String?, directory: String, displayLabel: String?) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    nonisolated func controlSidebarScheduleScopedShellState(scope: ControlSidebarPanelScope, stateRawValue: String) {}

    func controlSidebarUpdateShellState(tabArg: String?, panelArg: String?, stateRawValue: String) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    nonisolated func controlSidebarScheduleScopedTTY(scope: ControlSidebarPanelScope, ttyName: String) {}

    func controlSidebarReportTTY(tabArg: String?, panelArg: String?, ttyName: String) -> ControlSidebarPanelWriteResolution {
        .tabNotFound
    }

    nonisolated func controlSidebarScheduleScopedPortsKick(scope: ControlSidebarPanelScope, reasonRawValue: String) {}

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
