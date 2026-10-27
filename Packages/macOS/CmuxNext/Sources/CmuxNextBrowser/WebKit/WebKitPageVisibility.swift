import WebKit

/// Whether a WebKit browser tab's web view is hidden to WebKit (p14-energy-059, feature `webkitHiddenTabs`).
///
/// WebKit's `IsVisible` activity state is `-[NSView isHiddenOrHasHiddenAncestor]` of the web view in a visible
/// window (`PageClientImpl::isViewVisible`, Source/WebKit/UIProcess/mac/PageClientImplMac.mm), so the web view's
/// own `isHidden` makes the page hidden: `document.visibilityState` is "hidden", WebKit throttles its timers and
/// stops its rendering updates. Unlike a window move, it reloads nothing and does not wait for the web process.
/// A page the content lifecycle hides is hidden this way, as Chrome hides a background tab's renderer
/// (`WebContentsImpl::WasHidden`, content/browser/web_contents/web_contents_impl.cc), whatever hides the views
/// around it. The pages Memory Saver protects stay visible (p14-energy.md section 7): audible or Picture in Picture
/// media and camera or microphone capture (`CanDiscard` in
/// chrome/browser/performance_manager/policies/page_discarding_helper.cc), so a call or a player in a background
/// tab keeps WebKit's visible timers.
nonisolated struct WebKitPageVisibility: Equatable, Sendable {
    /// The app hides hidden pages from WebKit (``WebKitEngine/hidesHiddenTabs``).
    var followsContent = false
    /// The content lifecycle hid the page (`WebKitTab.setContentVisible(false)`).
    var contentHidden = false
    /// The page plays audible media, or its video floats in Picture in Picture.
    var playsMedia = false
    /// The page captures the camera or the microphone (a muted capture too).
    var captures = false

    /// The web view is hidden to WebKit.
    var hidesPage: Bool { followsContent && contentHidden && !playsMedia && !captures }
}

extension WKWebView {
    /// The page holds the camera or the microphone, active or muted.
    var capturesMedia: Bool { cameraCaptureState != .none || microphoneCaptureState != .none }
}
