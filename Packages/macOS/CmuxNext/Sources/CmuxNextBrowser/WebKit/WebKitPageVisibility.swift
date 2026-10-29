import WebKit

/// Whether a WebKit browser tab's web view is hidden to WebKit (feature `webkitHiddenTabs`).
///
/// WebKit's `IsVisible` activity state is `-[NSView isHiddenOrHasHiddenAncestor]` of the web view in a visible
/// window (`PageClientImpl::isViewVisible`, Source/WebKit/UIProcess/mac/PageClientImplMac.mm), so the web view's
/// own `isHidden` makes the page hidden: `document.visibilityState` is "hidden", WebKit throttles its timers and
/// stops its rendering updates. Unlike a window move, it reloads nothing and does not wait for the web process.
/// A page the content lifecycle hides is hidden this way, as Chrome hides a background tab's renderer
/// (`WebContentsImpl::WasHidden`, content/browser/web_contents/web_contents_impl.cc), whatever hides the views
/// around it. The pages Memory Saver protects stay visible (p14-energy.md section 7): audible or Picture in Picture
/// media, playing media the tab's mute silences, and camera or microphone capture (`CanDiscard` in
/// chrome/browser/performance_manager/policies/page_discarding_helper.cc), so a call or a player in a background
/// tab keeps WebKit's visible timers. A page an agent drives in its off-screen render window stays visible too.
///
/// ``WebKitPageContainer`` applies ``hidesPage``; it is the only writer of the web view's `isHidden`, and the
/// render-rate re-show hides the page through ``reshowing``.
nonisolated struct WebKitPageVisibility: Equatable, Sendable {
    /// The app hides hidden pages from WebKit (``WebKitEngine/hidesHiddenTabs``).
    var followsContent = false
    /// The content lifecycle hid the page (`WebKitTab.setContentVisible(false)`).
    var contentHidden = false
    /// The page plays media that Memory Saver keeps (``BrowserMediaState/keepsPageShown(tabMuted:)``).
    var playsMedia = false
    /// The page captures the camera or the microphone (a muted capture too).
    var captures = false
    /// An agent drives the page in its off-screen render window (`AgentRenderWindows`, `WebKitTab.setKeptRendering`).
    var keptRendering = false
    /// A render-rate change is in its hidden step (`WebKitRenderRate.reshow`).
    var reshowing = false

    /// The content lifecycle's hide reaches WebKit: nothing keeps the hidden page shown.
    var hidesContent: Bool { followsContent && contentHidden && !playsMedia && !captures && !keptRendering }
    /// The web view is hidden to WebKit.
    var hidesPage: Bool { reshowing || hidesContent }
}

nonisolated extension BrowserMediaState {
    /// Media that keeps a hidden page shown to WebKit, Memory Saver's rule (`BrowserHibernation+Probe`): audible,
    /// playing but silenced by the tab's mute, or floating in Picture in Picture.
    func keepsPageShown(tabMuted: Bool) -> Bool { isAudible || (isPlaying && tabMuted) || isPictureInPicture }
}

extension WKWebView {
    /// The page holds the camera or the microphone, active or muted.
    var capturesMedia: Bool { cameraCaptureState != .none || microphoneCaptureState != .none }
}
