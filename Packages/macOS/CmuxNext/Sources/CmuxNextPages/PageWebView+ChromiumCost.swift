public import AppKit
public import WebKit

// Red-commit stub (the next commit implements it): the API the tests of "a cmux page costs
// nothing while nobody sees it" call, with the base behavior, so the tests compile on the base
// and fail on what they check, not on a missing symbol.
extension PageWebView {
    /// Base: a Chromium page starts in init, so there is nothing to start.
    public func startWithoutShowing() {}

    /// Base: nothing freezes a hidden cmux page.
    @discardableResult
    public func freezeWhileHidden() -> Bool { false }

    /// Base: a Chromium page never waits for its first show.
    public var isWaitingForFirstShow: Bool { false }

    /// Base: never frozen.
    public var isChromiumFrozen: Bool { false }

    /// Base: every document call goes to the WebKit view, also in Chromium mode.
    public var documentWebView: WKWebView? { webView }
}
