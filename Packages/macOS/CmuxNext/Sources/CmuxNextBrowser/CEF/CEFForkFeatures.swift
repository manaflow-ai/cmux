/// What the running Chromium fork offers, by its API number (`cmux_shim_fork_api_version`) and the
/// shim's exports, for the paths that switch on it.
nonisolated struct CEFForkFeatures: Equatable, Sendable {
    /// The first fork API with the renderer paths: document-start scripts and page channels in
    /// the renderer, script evaluation without DevTools, `SetPageFrozen`, a native click, and the
    /// `cmux-process-reuse-per-renderer-devtools` switch (CEF cmux.35).
    static let rendererPathsForkAPI: Int32 = 29
    /// The p14 energy bundle (manaflow-ai/cef `cp/p14-energy-136`): every p14 fork patch
    /// under the one number after ``CEFLayerHosting/resizeFenceForkAPI``. A pump pass holds the main thread
    /// for at most 2 ms plus one task (037), and the fork has `cmux_set_on_schedule_delayed` (046),
    /// `cmux_cef_browser_renderer_pid` (124) and `cmux_cef_set_energy_saver` (029). The shim binds those by
    /// symbol, so an older fork keeps the millisecond pump path, no renderer pid and no saver.
    static let p14BundleForkAPI: Int32 = 33
    /// The first fork API with `cmux_cef_set_energy_saver`: the p14 bundle.
    static let energySaverForkAPI: Int32 = p14BundleForkAPI

    /// The first fork API that reads PL-memory's `cmux-page-scheme-process-per-site` and has
    /// `cmux_page_scheme_set_group` (`libcef/browser/cmux/cmux_page_groups.cc`). The fork
    /// train (manaflow-ai/cef `cp/p13-webui-086`) numbers it 42; 32 is the resize fence's.
    static let pageSiteSharingForkAPI: Int32 = 42

    /// The first fork API with `cmux_tab_set_visibility`: the tab's visibility tree node caps
    /// its WebContents' visibility, and a capture keeps a hidden tab painting (`IncrementCapturerCount`). Max + 1 of
    /// the fork lines (36 is p03-rendering-044's attached views) and of the numbers the app claims.
    static let tabVisibilityForkAPI: Int32 = 37

    /// The first fork API with `cmux_browser_capture`: a page's surface copy with no DevTools agent.
    /// The fork train (manaflow-ai/cef `cp/p13-webui-086`) numbers it 40; 38 and 39 are the train's
    /// renderer-less placeholder (017) and in-place discard (018).
    static let surfaceCopyForkAPI: Int32 = 40
    /// The first fork API with `cmux_shim_tab_send_mouse_move` (`CefBrowserHost::SendMouseMoveEvent`): the same fork
    /// line as the surface copy (p13-webui-077 adds both), numbered by the train with it.
    static let mouseMoveForkAPI: Int32 = surfaceCopyForkAPI
    /// The first fork API with `cmux_tab_page_push` and `cmuxPageListen` (manaflow-ai/cef
    /// `cp/p13-webui-079` on `cp/p06-scheduler-212`): a string to a cmux-page document's receiver, with no script.
    /// The fork train reserves 43 for it, after its 38-42 (42 is ``pageSiteSharingForkAPI``); the
    /// 079 commit's own header says 38, which the train renumbers when it merges it.
    static let pagePushForkAPI: Int32 = 43

    /// The first fork API whose page window joins the app's Core Animation commit only for a deadline
    /// the app set (`cmux_browser_set_resize_sync`). With none, `UpdateWindowGeometry` does not call
    /// `CATransactionCoordinator::Synchronize`, so a resize waits neither before the commit (up to
    /// `kUIPaintTimeout`, 500 ms) nor after it for the GPU's reply (`kPostCommitTimeout`, 50 ms):
    /// Chromium's `ui/accelerated_widget_mac/ca_transaction_observer.mm`, fork e07a2f78
    /// (`cef_cmux.h` "API 27"; the earlier, never released API 27 commits lack the skip).
    static let resizeSyncForkAPI: Int32 = 27

    /// `cmux_shim_fork_api_version()`; 0 for stock CEF or no shim.
    var forkAPIVersion: Int32
    /// The shim exports every renderer-path call (`CEFShimLibrary.hasRendererPaths`).
    var shimHasRendererPaths: Bool
    /// The shim exports `cmux_shim_tab_set_visibility` (`CEFShimLibrary.tabSetVisibility`).
    var shimHasTabVisibility = false
    /// The shim exports `cmux_shim_tab_copy_surface` (`CEFShimLibrary.tabCopySurface`).
    var shimHasSurfaceCopy = false
    /// The shim exports `cmux_shim_tab_send_mouse_move` (`CEFShimLibrary.tabSendMouseMove`).
    var shimHasMouseMove = false
    /// The shim exports `cmux_shim_tab_page_push` (`CEFShimLibrary.tabPagePush`).
    var shimHasPagePush = false

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

    /// Chromium copies a page's surface and encodes it on its thread pool (``CEFTab/copySurface(maxPixelSize:)``), as
    /// Chrome copies a tab thumbnail (`RenderWidgetHostView::CopyFromSurface`): a picture attaches no DevTools agent,
    /// so the renderer stays shareable. Below this API a picture needs `Page.captureScreenshot`.
    var surfaceCopy: Bool { shimHasSurfaceCopy && forkAPIVersion >= Self.surfaceCopyForkAPI }

    /// A mouse move with no button reaches the page as the person's own (``CEFTab/sendMouseMove(x:y:)``), with no
    /// DevTools agent, as the native click does. Below this API a scripted hover needs DevTools input.
    var mouseMove: Bool { shimHasMouseMove && forkAPIVersion >= Self.mouseMoveForkAPI }

    /// A cmux page can get its host events and replies as data (``CEFPagePush``): the page registers a
    /// receiver with `cmuxPageListen` and each push calls it with a string, as Chrome's WebUI pages get Mojo
    /// messages instead of a script per call. Below this API, or with an older shim, every delivery is a script.
    var pagePush: Bool { shimHasPagePush && forkAPIVersion >= Self.pagePushForkAPI }

    /// A page-window resize holds the app's commit only while the app gives that page a deadline.
    /// Below it Chromium 154 waits on every resize, so `CEFSwitches` keeps `AsyncLiveResize` on.
    var resizeWaitsOnlyForDeadline: Bool { forkAPIVersion >= Self.resizeSyncForkAPI }
}

extension CEFForkFeatures {
    /// The features of a loaded shim.
    init(_ shim: CEFShimLibrary) {
        self.init(forkAPIVersion: shim.forkAPIVersion(), shimHasRendererPaths: shim.hasRendererPaths,
                  shimHasTabVisibility: shim.tabSetVisibility != nil, shimHasSurfaceCopy: shim.tabCopySurface != nil,
                  shimHasMouseMove: shim.tabSendMouseMove != nil, shimHasPagePush: shim.tabPagePush != nil)
    }
}
