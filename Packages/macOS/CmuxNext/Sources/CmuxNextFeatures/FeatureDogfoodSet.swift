/// The switch set a dogfood build opens with, so it works when double-clicked, with no launch environment
/// (Lawrence 2026-10-27, handoff cmux-lead-dogfood-2.md). A build whose shipped tag (the fleet's `--tag`, the bundle's
/// `CMUX_TAG`) starts with ``tagPrefix`` resolves ``names`` on by default (``FeatureOverrides/buildDefaults``), under
/// every other input, so `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES` still override one launch. Every other
/// build (DEV, NIGHTLY and Release) keeps its channel defaults. Bench-only switches are never in a set: perfLabCanary
/// delays every key press by 2 ms and perfLabKillProbe kills processes on purpose; nor are switches whose own description
/// says to turn them on later (cefLayerHostingEveryPage, hangReportsSchema3), nor chromiumAdBlockerAtFirstTab until a
/// pinned fork has the first-tab load (fork API 41): on a fork without it the feature runs no built-in ad blocker.
public nonisolated struct FeatureDogfoodSet: Sendable, Equatable {
    /// The chrome-parity dogfood builds (`chrome-parity-v2-1`, ...): every switch the chrome-parity work added that is
    /// off by default in DEV, less the ones above. Names this build's registry does not declare are ignored, as
    /// ``FeatureList`` ignores unknown names in any input.
    public static let chromeParity = FeatureDogfoodSet(tagPrefix: "chrome-parity-", names: [
        "agentChromium",
        "agentPageRendererSharing",
        "automationBurstSnap",
        "browserLaunchPictures",
        "cefAttachedPages",
        "cefHelperHost",
        "cefLaunchOrigin",
        "cefLayerHosting",
        "cefMergedEvents",
        "cefPrefetchBehindFence",
        "cefPumpInputPolicy",
        "cefTimerSlack",
        "chromiumHostDragIn",
        "chromiumHostFileDialogs",
        "chromiumHostIdleExit",
        "chromiumHostPopupMenus",
        "chromiumHostResizeFence",
        "chromiumHostSuggestions",
        "chromiumHostWidgets",
        "chromiumSpareAfterFirstTab",
        "chromiumTabVisibility",
        "cmuxPageRendererSharing",
        "coldScrollbackCompression",
        "compressedSnapshots",
        "controlSocketEarlyBind",
        "daemonRequestQos",
        "directionalPrewarm",
        "energySaver",
        "featureFlagsCard",
        "frameRateClasses",
        "frozenGrowthDiscard",
        "hiddenPollPause",
        "highEnergyTabs",
        "hostPressure",
        "intentPrewarmHover",
        "intentPrewarmPress",
        "ipcMethodLatencyFieldData",
        "launchVisiblePanesOnly",
        "launchWindowsByOcclusion",
        "leftoverDaemonIdleExit",
        "memoryAcpmuxPressure",
        "memoryAgentAndControlCaches",
        "memoryAppCaches",
        "memoryBackdropImages",
        "memoryBrowserCaches",
        "memoryDiscardAgentPagesOverBudget",
        "memoryDiscardConversations",
        "memoryDiscardInternalPages",
        "memoryDiscardPageTabs",
        "memoryDiscardParkedIdleTimeout",
        "memoryDiscardParkedWorkspaces",
        "memoryDiscardRemoteTabs",
        "memoryDiscardSidebarSections",
        "memoryFileHomeCaches",
        "memoryHiddenAppRelease",
        "memoryHiddenFrameLRU",
        "memoryHomeLabCaches",
        "memoryImageCaches",
        "memoryKittyShare",
        "memoryOpenPanelOnFirstUse",
        "memoryOverlayPagesOnFirstUse",
        "memorySaverBackgroundActivity",
        "memorySaverSetting",
        "memoryScrollbackPressure",
        "memoryTabCaches",
        "memoryTerminalLastFrames",
        "memoryUrgentDiscardRanking",
        "metricsView",
        "newTabParksHidden",
        "occludedWindowDiscard",
        "overlayTopLayer",
        "pageHangNotice",
        "pageLifecycle",
        "pageProcessGroups",
        "pageRendererAtFirstShow",
        "pageScriptFrames",
        "pageStandIn",
        "pageTabsShareChromiumWindow",
        "pagesSpareWindow",
        "paneHoldsContentInMotion",
        "pointerFrameDrags",
        "pointerFrameHover",
        "pointerFrameRemoteInput",
        "recentlyAudibleProtection",
        "renderStarvationGuard",
        "rendererlessSpareWindow",
        "resampledDrags",
        "savedWindowPicture",
        "sentryHandlersFirst",
        "sharedGlyphMasks",
        "sidebarRowsNearViewport",
        "sidebarSlideHoldsContent",
        "sleepWakeKeepalives",
        "stripPanResampling",
        "taskManagerMemorySaved",
        "terminalGPURelease",
        "terminalPointerFrames",
        "terminalSizingPerApp",
        "topPageDiscard",
        "visibilityGatedHosting",
        "vsyncHub",
        "windowOcclusionFamily",
    ])

    /// The tag prefix of the builds this set is for.
    public let tagPrefix: String
    /// The features on by default in those builds.
    public let names: Set<String>

    public init(tagPrefix: String, names: Set<String>) {
        self.tagPrefix = tagPrefix
        self.names = names
    }

    /// The build defaults of a build that ships `tag`: ``names`` for one of this set's tags, else none.
    public func buildDefaults(forTag tag: String?) -> Set<String> {
        guard let tag, tag.hasPrefix(tagPrefix) else { return [] }
        return names
    }
}
