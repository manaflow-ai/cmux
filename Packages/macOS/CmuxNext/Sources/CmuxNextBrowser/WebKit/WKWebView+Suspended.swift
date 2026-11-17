package import WebKit

/// Whether WebKit holds this web view's page suspended (`-[WKWebView _suspendPage:]`, which a hidden tab's
/// freeze sends: `WebKitTab+Freeze`). A suspended WKWebView raises `NSInternalInconsistencyException`
/// ("The WKWebView is suspended") from about 150 of its calls (scripts, snapshot, find, loads, stop, zoom,
/// mute, downloads, print, user agent), and Swift cannot catch an Objective-C exception: NIGHTLY
/// 1.0.0-nightly.4376544293601 crashed when the history writer measured a frozen tab's scroll
/// (https://github.com/manaflow-ai/cmux/issues/44019). Read this right before such a call, in the same
/// main-actor turn.
///
/// WebKit's own `_isSuspended` is not this: it answers the web process's RunningBoard throttle state, while
/// the throw checks the page's `WebPageProxy::m_isSuspended`. WebKit sets that flag only in `suspend` and
/// clears it only in `resume`, each synchronously and only for a page whose process runs, so cmux keeps the
/// same flag where it sends them (`WebKitWebView.pageSuspended`).
extension WKWebView {
    package var cmuxIsSuspended: Bool { (self as? WebKitWebView)?.pageSuspended ?? false }
}
