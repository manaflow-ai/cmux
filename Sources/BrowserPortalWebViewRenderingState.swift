import AppKit
import ObjectiveC
import WebKit

/// Hidden/visible rendering-state tracking for portal-hosted webviews,
/// extracted from BrowserWindowPortal.swift.
///
/// WKWebView suspends parts of its rendering pipeline while hosted in a
/// hidden or alpha-0 window. When such a webview becomes visible again (a
/// portal reveal, or adoption out of the prewarm pool's offscreen host), the
/// refresh pass must fire WebKit's re-enter selectors or the first paint
/// keeps the stale layer tree from the hidden host.

private var cmuxBrowserPortalNeedsRenderingStateReattachKey: UInt8 = 0

#if DEBUG
private func browserPortalRenderingStateDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}
#endif

private extension NSObject {
    @discardableResult
    func browserPortalCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }
}

extension WKWebView {
    fileprivate var browserPortalNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, &cmuxBrowserPortalNeedsRenderingStateReattachKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxBrowserPortalNeedsRenderingStateReattachKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var browserPortalRequiresRenderingStateReattach: Bool {
        browserPortalNeedsRenderingStateReattach
    }

    /// A pool-prewarmed webview loads inside an alpha-0 offscreen window, so
    /// WebKit treats it as hidden. Adoption into a visible pane needs the same
    /// rendering-state reattach as a portal-hidden webview, otherwise the
    /// first paint keeps the prewarm-sized layer tree (undersized content and
    /// a short scrollbar) until an unrelated relayout.
    func browserPortalPrepareForHiddenHostAdoption() {
        browserPortalNotifyHidden(reason: "prewarmAdoption")
    }

    func browserPortalNotifyHidden(reason: String) {
        browserPortalNeedsRenderingStateReattach = true
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPortalCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            cmuxDebugLog(
                "browser.portal.webview.hidden web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    func browserPortalReattachRenderingState(reason: String) {
        guard browserPortalNeedsRenderingStateReattach else { return }
        guard window != nil else { return }
        browserPortalNeedsRenderingStateReattach = false

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPortalCallVoidIfAvailable($0)
        }

        if let scrollView = enclosingScrollView {
            scrollView.needsLayout = true
            scrollView.needsDisplay = true
            scrollView.setNeedsDisplay(scrollView.bounds)
            scrollView.contentView.needsLayout = true
            scrollView.contentView.needsDisplay = true
        }

        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)

#if DEBUG
        if !firedSelectors.isEmpty {
            cmuxDebugLog(
                "browser.portal.webview.reattach web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(String(format: "%.1f,%.1f %.1fx%.1f", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height))"
            )
        }
#endif
    }
}
