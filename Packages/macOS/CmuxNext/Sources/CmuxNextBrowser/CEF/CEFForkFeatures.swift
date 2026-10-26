/// What the running Chromium fork offers, by its API number (`cmux_shim_fork_api_version`) and the
/// shim's exports, for the paths that switch on it.
nonisolated struct CEFForkFeatures: Equatable, Sendable {
    /// The first fork API with the renderer paths: document-start scripts and page channels in
    /// the renderer, script evaluation without DevTools, `SetPageFrozen`, a native click, and the
    /// `cmux-process-reuse-per-renderer-devtools` switch (CEF cmux.35).
    static let rendererPathsForkAPI: Int32 = 29
    /// The first fork API with `cmux_cef_set_energy_saver` (p14-energy-029): the one after the resize fence
    /// (``CEFLayerHosting/resizeFenceForkAPI``), which the fork bundle p14-energy-136 sets with its pin.
    static let energySaverForkAPI: Int32 = 33

    /// The first fork API that reads PL-memory's `cmux-page-scheme-process-per-site` (manaflow-ai/cef
    /// `cp/p13-webui-011` at 17a7f8ff, `libcef/browser/cmux/cmux_page_groups.cc`). That commit has no
    /// number of its own: the fork train ledger (`scripts/cmux-next/cef-fork-train.json`, p07-memory 074)
    /// gives each unnumbered export the train's API, 32. This gate moves with the train's number.
    static let pageSiteSharingForkAPI: Int32 = 32

    /// The first fork API with `cmux_tab_set_visibility` (p06-scheduler-212): the tab's visibility tree node caps
    /// its WebContents' visibility, and a capture keeps a hidden tab painting (`IncrementCapturerCount`). Max + 1 of
    /// the fork lines (36 is p03-rendering-044's attached views) and of the numbers the app claims.
    static let tabVisibilityForkAPI: Int32 = 37

    /// `cmux_shim_fork_api_version()`; 0 for stock CEF or no shim.
    var forkAPIVersion: Int32
    /// The shim exports every renderer-path call (`CEFShimLibrary.hasRendererPaths`).
    var shimHasRendererPaths: Bool
    /// The shim exports `cmux_shim_tab_set_visibility` (`CEFShimLibrary.tabSetVisibility`).
    var shimHasTabVisibility = false

    /// No always-on per-tab DevTools session: a tab gets a DevTools agent only when DevTools opens
    /// or an agent drives it over CDP, so Chrome's process reuse can put up to 2 same-site main
    /// frames in one renderer (kProcessPerSiteUpToMainFrameThreshold; plans/cmux-next/tab-lifecycle.md
    /// "Renderer sharing"). Both the fork and the shim must have them: the same app runs on an
    /// older CEF with the DevTools path.
    var rendererPaths: Bool { shimHasRendererPaths && forkAPIVersion >= Self.rendererPathsForkAPI }

    /// Chromium takes Energy Saver from the app (``CEFEnergySaver``): frame sinks at 30 Hz except cmux's own
    /// pages and sinks with recent input, 32 ms wake alignment, battery saver mode in child processes. Below
    /// this API the app makes no call (the shim also returns 0 when the fork lacks the symbol).
    var energySaver: Bool { forkAPIVersion >= Self.energySaverForkAPI }

    /// Chromium takes each tab's visibility from its node (``CEFTab/followVisibility(of:capture:)``): hidden and
    /// occluded tabs are hidden and occluded to Blink in the node's turn. Below this API the page window and its
    /// view decide alone, as before.
    var tabVisibility: Bool { shimHasTabVisibility && forkAPIVersion >= Self.tabVisibilityForkAPI }
}

extension CEFForkFeatures {
    /// The features of a loaded shim.
    init(_ shim: CEFShimLibrary) {
        self.init(forkAPIVersion: shim.forkAPIVersion(), shimHasRendererPaths: shim.hasRendererPaths,
                  shimHasTabVisibility: shim.tabSetVisibility != nil)
    }
}
