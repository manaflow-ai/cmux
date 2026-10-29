import AppKit
import IOSurface

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
        /// `cmux_shim_browser_set_resize_fence` (``resizeFenceForkAPI``) and the runtime's
        /// transactions (``CEFLayerHosting/viewDidResize()``); nil on older forks, in host mode and
        /// while the feature `cefResizeFence` is off. With it ``trackA`` has ``TrackA/resizeFence``.
        let resizeFence: ResizeFence?
        /// The Track A calls the app makes for this fork's pages while the
        /// feature `cefLayerHosting` is on; nil while it is off.
        let trackA: TrackA?
        /// `cmux_shim_browser_attach_view` (Track B) from fork API ``CEFLayerHosting/attachViewForkAPI`` while the
        /// feature `cefAttachedPages` is on; nil otherwise.
        let attachView: CEFAttachedPages.Attach?
        /// `cmux_browser_set_embedder_visibility`: the
        /// page window's visibility comes from the app, never from its window's
        /// order or occlusion. True when the fork took it. Nil without the call:
        /// the fork follows the host view in the switch's turn.
        let setVisibility: ((_ browser: Int32, _ visibility: PageVisibility) -> Bool)?
        /// The fork's keep-frame-while-hidden call: drops the frame a hidden page
        /// window kept for its next show (the app's ``CEFHiddenFrames`` decides
        /// when). Nil: Chromium's own frame eviction decides.
        let evictFrame: ((_ browser: Int32) -> Bool)?
        /// The fork's copy of a hidden page window's last frame into a new IOSurface the app owns:
        /// made on the fork's GPU thread, delivered once on the main thread (nil when
        /// there was no frame), as Chromium's `CopyFromCompositingSurface` answers on its UI thread.
        /// False when no copy was started. Nil without the call.
        let copyFrame: ((_ browser: Int32, _ done: @escaping @MainActor (IOSurface?) -> Void) -> Bool)?
        /// Calls `presented` once, on the main thread, when the page window presents its next frame
        /// or can present none (its renderer went away): Chromium's first surface activation after a
        /// show. False when the fork cannot tell. Nil without the call.
        let onNextFrame: ((_ browser: Int32, _ presented: @escaping @MainActor () -> Void) -> Bool)?
        /// The kinds of page window `setLayerHosting` hosts; the feature's default hosts no other
        /// (``CEFLayerHosting/hosting(override:fork:widget:)``).
        let hostedWidgets: Set<Widget>
        /// The kinds of page window whose view `attachView` attaches (``CEFLayerHosting/attaches(fork:widget:)``).
        let attachedWidgets: Set<Widget>

        init(setLayerHosting: @escaping (_ browser: Int32, _ enabled: Bool) -> UInt32,
             setResizeSync: ((_ browser: Int32, _ timeoutMs: Int32) -> Bool)? = nil,
             resizeFence: ResizeFence? = nil,
             trackA: TrackA? = nil, attachView: CEFAttachedPages.Attach? = nil,
             setVisibility: ((_ browser: Int32, _ visibility: PageVisibility) -> Bool)? = nil,
             evictFrame: ((_ browser: Int32) -> Bool)? = nil,
             copyFrame: ((_ browser: Int32, _ done: @escaping @MainActor (IOSurface?) -> Void) -> Bool)? = nil,
             onNextFrame: ((_ browser: Int32, _ presented: @escaping @MainActor () -> Void) -> Bool)? = nil,
             hostedWidgets: Set<Widget> = [.page], attachedWidgets: Set<Widget> = [.page]) {
            self.setLayerHosting = setLayerHosting
            self.setResizeSync = setResizeSync
            self.resizeFence = resizeFence
            self.trackA = trackA
            self.attachView = attachView
            self.setVisibility = setVisibility
            self.evictFrame = evictFrame
            self.copyFrame = copyFrame
            self.onNextFrame = onNextFrame
            self.hostedWidgets = hostedWidgets
            self.attachedWidgets = attachedWidgets
        }

        /// The shim's call; nil without a shim or below fork API 26, where
        /// nothing changes and showing a tab costs nothing here. From fork API 34
        /// the app gives a hosted page its visibility, so the feature's Track A
        /// calls include ``TrackA/embedderVisibility``. `fences` is the runtime's one set of resize
        /// transactions, shared by every page (nil while the feature `cefResizeFence` is off): from
        /// ``CEFLayerHosting/resizeFenceForkAPI``, with the shim's in-process fence call, each resize
        /// joins one (``resizeFence``) and the Track A calls include ``TrackA/resizeFence``.
        init?(shim: CEFShimLibrary?, apiVersion: Int32, policy: Policy = Policy(), fences: CEFResizeFences? = nil) {
            guard let shim, apiVersion >= CEFLayerHosting.forkAPI else { return nil }
            setLayerHosting = { browser, enabled in shim.browserSetLayerHosting(browser, enabled ? 1 : 0) }
            setResizeSync = CEFLayerHosting.hasResizeSync(apiVersion: apiVersion)
                ? { browser, timeout in shim.browserSetResizeSync(browser, timeout) == 1 } : nil
            let setFence = apiVersion >= CEFLayerHosting.resizeFenceForkAPI ? shim.browserSetResizeFence : nil
            resizeFence = fences.flatMap { fences in
                setFence.map { call in
                    ResizeFence(fences: fences, set: { browser, fence, frames in call(browser, fence, frames) == 1 })
                }
            }
            var calls = policy.trackA
            if resizeFence != nil { calls = calls?.union(.resizeFence) }
            if apiVersion >= CEFLayerHosting.embedderVisibilityForkAPI, let call = shim.browserSetEmbedderVisibility {
                setVisibility = { browser, visibility in call(browser, visibility.rawValue) == 1 }
                calls = calls?.union(.embedderVisibility)
            } else {
                setVisibility = nil
            }
            trackA = calls
            attachView = CEFAttachedPages.shimAttach(shim, apiVersion: apiVersion, enabled: policy.attachesViews)
            // The fork's keep-frame-while-hidden call has no shim export yet: Chromium's own eviction decides.
            evictFrame = nil
            // The fork's frame copy and next-frame calls come with the same exports.
            copyFrame = nil
            onNextFrame = nil
            // Fork APIs 26 and 33 host and attach a tab's page window only. A DevTools frontend and a popup
            // window's tab need the fork's per-widget hosting and attach, which no fork API has yet.
            hostedWidgets = [.page]
            attachedWidgets = [.page]
        }

        /// A page window `runtime` made in process, with its features' calls.
        init?(runtime: CEFRuntime) {
            self.init(shim: runtime.shim, apiVersion: runtime.forkAPIVersion, policy: runtime.pageHosting,
                      fences: runtime.resizeFences)
        }
    }

    /// A page's way into a geometry transaction's fence (``CEFResizeFences``).
    struct ResizeFence {
        let fences: CEFResizeFences
        let set: CEFResizeFences.SetFence
    }
}
