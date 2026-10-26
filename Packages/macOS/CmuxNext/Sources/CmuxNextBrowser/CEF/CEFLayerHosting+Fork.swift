import AppKit

/// The fork calls a page window's ``CEFLayerHosting`` makes, from the shim and the features.
extension CEFLayerHosting {
    /// The fork's layer hosting call: a seam, so tests run this state machine
    /// without Chromium.
    struct Fork {
        /// `cmux_shim_browser_set_layer_hosting`: the page window's context
        /// id (> 0) for `enabled`, 0 when off or refused.
        let setLayerHosting: (_ browser: Int32, _ enabled: Bool) -> UInt32
        /// `cmux_shim_browser_set_resize_sync` (fork API 27): how long a
        /// resize of the page window may hold the commit for Chromium's frame
        /// at the new size, in ms; 0 never holds it. True when the fork took it
        /// (false for a closed browser's id). Nil below API 27, where Chromium
        /// holds it up to 500 ms on every resize, and from API 32, where the
        /// fork never holds it (``hasResizeSync(apiVersion:)``).
        let setResizeSync: ((_ browser: Int32, _ timeoutMs: Int32) -> Bool)?
        /// The Track A calls the app makes for this fork's pages while the
        /// feature `cefLayerHosting` is on; nil while it is off.
        let trackA: TrackA?
        /// `cmux_shim_browser_attach_view` (Track B) from fork API ``CEFLayerHosting/attachViewForkAPI`` while the
        /// feature `cefAttachedPages` is on; nil otherwise.
        let attachView: CEFAttachedPages.Attach?

        init(setLayerHosting: @escaping (_ browser: Int32, _ enabled: Bool) -> UInt32,
             setResizeSync: ((_ browser: Int32, _ timeoutMs: Int32) -> Bool)? = nil,
             trackA: TrackA? = nil, attachView: CEFAttachedPages.Attach? = nil) {
            self.setLayerHosting = setLayerHosting
            self.setResizeSync = setResizeSync
            self.trackA = trackA
            self.attachView = attachView
        }

        /// The shim's call; nil without a shim or below fork API 26, where
        /// nothing changes and showing a tab costs nothing here.
        init?(shim: CEFShimLibrary?, apiVersion: Int32, policy: Policy = Policy()) {
            guard let shim, apiVersion >= CEFLayerHosting.forkAPI else { return nil }
            setLayerHosting = { browser, enabled in shim.browserSetLayerHosting(browser, enabled ? 1 : 0) }
            setResizeSync = CEFLayerHosting.hasResizeSync(apiVersion: apiVersion)
                ? { browser, timeout in shim.browserSetResizeSync(browser, timeout) == 1 } : nil
            trackA = policy.trackA
            attachView = CEFAttachedPages.shimAttach(shim, apiVersion: apiVersion, enabled: policy.attachesViews)
        }

        /// A page window `runtime` made in process, with its features' calls.
        init?(runtime: CEFRuntime) {
            self.init(shim: runtime.shim, apiVersion: runtime.forkAPIVersion, policy: runtime.pageHosting)
        }
    }
}
