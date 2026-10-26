/// What the running Chromium fork offers, by its API number (`cmux_shim_fork_api_version`) and the
/// shim's exports, for the paths that switch on it.
nonisolated struct CEFForkFeatures: Equatable, Sendable {
    /// The first fork API with the renderer paths: document-start scripts and page channels in
    /// the renderer, script evaluation without DevTools, `SetPageFrozen`, a native click, and the
    /// `cmux-process-reuse-per-renderer-devtools` switch (CEF cmux.35).
    static let rendererPathsForkAPI: Int32 = 29

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

    /// No always-on per-tab DevTools session: a tab gets a DevTools agent only when DevTools opens
    /// or an agent drives it over CDP, so Chrome's process reuse can put up to 2 same-site main
    /// frames in one renderer (kProcessPerSiteUpToMainFrameThreshold; plans/cmux-next/tab-lifecycle.md
    /// "Renderer sharing"). Both the fork and the shim must have them: the same app runs on an
    /// older CEF with the DevTools path.
    var rendererPaths: Bool { shimHasRendererPaths && forkAPIVersion >= Self.rendererPathsForkAPI }

    /// A page-window resize holds the app's commit only while the app gives that page a deadline.
    /// Below it Chromium 154 waits on every resize, so `CEFSwitches` keeps `AsyncLiveResize` on.
    var resizeWaitsOnlyForDeadline: Bool { forkAPIVersion >= Self.resizeSyncForkAPI }
}

extension CEFForkFeatures {
    /// The features of a loaded shim.
    init(_ shim: CEFShimLibrary) {
        self.init(forkAPIVersion: shim.forkAPIVersion(), shimHasRendererPaths: shim.hasRendererPaths)
    }
}
