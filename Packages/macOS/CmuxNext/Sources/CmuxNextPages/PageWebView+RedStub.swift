public import AppKit
public import WebKit

// VERIFY ONLY (pl-pages-cost-redstub, never lands): the API the red tests call, with the base
// behavior, so PageChromiumCostTests compiles on the base and shows its real failures.
@MainActor
public protocol PageFreezePolicy: AnyObject {
    func hiddenPageWoke(_ page: PageWebView)
    func pageIsNoLongerHidden(_ page: PageWebView)
}

extension PageWebView {
    /// Base: every document call goes to the WebKit view.
    public var documentWebView: WKWebView? { webView }
    /// Base: the page starts in init.
    public func startWithoutShowing() {}
    /// Base: nothing freezes a hidden cmux page.
    public func freezeWhileHidden() -> Bool { false }
    /// Base: never frozen.
    public var isChromiumFrozen: Bool { false }
}
