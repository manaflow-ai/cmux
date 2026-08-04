import AppKit
import CmuxBrowser
import WebKit

/// Lazily activated presentation host that maps a logical browser viewport into pane geometry.
///
/// Scaling the host's bounds, rather than only the `WKWebView` bounds, gives WebKit a real
/// layout size while preserving the pane's displayed size and AppKit coordinate conversion.
/// Native browsers stay directly attached to their portal container so this extra AppKit layer
/// exists only while an automation viewport is active.
@MainActor
final class BrowserViewportHostView: NSView {
    private(set) weak var webView: WKWebView?
    private(set) var appliedLayout: BrowserViewportLayout?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func installWebView(_ nextWebView: WKWebView) {
        if webView === nextWebView {
            nextWebView.cmuxBrowserViewportHostView = self
            if hasActiveViewport(for: nextWebView) {
                restoreWebViewIfNeeded()
            }
            return
        }

        if let previousWebView = webView {
            if previousWebView.cmuxBrowserViewportHostView === self {
                previousWebView.cmuxBrowserViewportHostView = nil
            }
            if previousWebView.superview === self {
                previousWebView.removeFromSuperview()
            }
        }

        webView = nextWebView
        nextWebView.cmuxBrowserViewportHostView = self
        if hasActiveViewport(for: nextWebView) {
            restoreWebViewIfNeeded()
        } else if subviews.isEmpty {
            appliedLayout = nil
            removeFromSuperview()
        }
    }

    @discardableResult
    func restoreWebViewIfNeeded() -> Bool {
        guard let webView else { return false }
        guard hasActiveViewport(for: webView) else { return false }
        guard webView.superview !== self else {
            applyRawWebViewGeometryIfSafe()
            return false
        }
        guard webView.superview == nil else { return false }

        addSubview(webView)
        applyRawWebViewGeometryIfSafe()
        return true
    }

    @discardableResult
    func restoreWebViewAfterExternalGeometryIfSafe() -> Bool {
        guard let webView else { return false }
        guard hasActiveViewport(for: webView) else { return false }
        guard webView.superview !== self else {
            applyRawWebViewGeometryIfSafe()
            return false
        }
        guard !webView.cmuxIsElementFullscreenActiveOrTransitioning else { return false }
        if let rawSuperview = webView.superview,
           rawSuperview.browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            return false
        }
        if browserPortalHasVisibleWebKitCompanionSubview(for: webView) {
            return false
        }

        let rawSuperview = webView.superview
        let rawFrame = webView.frame
        let rawBounds = webView.bounds
        let rawAutoresizingMask = webView.autoresizingMask
        let rawTranslatesAutoresizingMaskIntoConstraints = webView.translatesAutoresizingMaskIntoConstraints
        let rawSiblings = rawSuperview?.subviews ?? []
        let rawIndex = rawSiblings.firstIndex(of: webView)
        let previousSibling = rawIndex.flatMap { index in
            index > 0 ? rawSiblings[index - 1] : nil
        }

        webView.removeFromSuperview()
        if let rawSuperview, superview !== rawSuperview {
            removeFromSuperview()
            if let previousSibling, previousSibling.superview === rawSuperview {
                rawSuperview.addSubview(self, positioned: .above, relativeTo: previousSibling)
            } else if let firstSibling = rawSuperview.subviews.first {
                rawSuperview.addSubview(self, positioned: .below, relativeTo: firstSibling)
            } else {
                rawSuperview.addSubview(self)
            }
            frame = rawFrame
            bounds = rawBounds
            autoresizingMask = rawAutoresizingMask
            translatesAutoresizingMaskIntoConstraints = rawTranslatesAutoresizingMaskIntoConstraints
        }
        addSubview(webView)
        if let containerBounds = superview?.bounds,
           let layout = webView.cmuxBrowserViewportLayout(in: containerBounds) {
            apply(layout)
        } else {
            applyRawWebViewGeometryIfSafe()
        }
        return true
    }

    /// Replaces this host with its raw web view when pane geometry becomes authoritative again.
    ///
    /// The raw view is inserted at the host's exact sibling position so portal overlays and hit
    /// testing retain their ordering across native → emulated → native transitions.
    @discardableResult
    func deactivateWebView(using nativeLayout: BrowserViewportLayout) -> Bool {
        guard let webView, webView.superview === self else {
            webView?.cmuxApplyBrowserViewportLayout(nativeLayout)
            if subviews.isEmpty {
                appliedLayout = nil
                removeFromSuperview()
            }
            return false
        }
        guard !browserPortalHasVisibleWebKitCompanionSubview(for: webView) else {
            apply(nativeLayout, updateWebView: false)
            return false
        }

        let container = superview
        let hostFrame = frame
        let hostBounds = bounds
        let hostAutoresizingMask = autoresizingMask
        let hostTranslatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
        let siblings = container?.subviews ?? []
        let hostIndex = siblings.firstIndex(of: self)
        let previousSibling = hostIndex.flatMap { index in
            index > 0 ? siblings[index - 1] : nil
        }

        webView.removeFromSuperview()
        removeFromSuperview()

        if let container {
            if let previousSibling, previousSibling.superview === container {
                container.addSubview(webView, positioned: .above, relativeTo: previousSibling)
            } else if let firstSibling = container.subviews.first {
                container.addSubview(webView, positioned: .below, relativeTo: firstSibling)
            } else {
                container.addSubview(webView)
            }
        } else {
            webView.frame = hostFrame
            webView.bounds = hostBounds
            webView.autoresizingMask = hostAutoresizingMask
            webView.translatesAutoresizingMaskIntoConstraints = hostTranslatesAutoresizingMaskIntoConstraints
        }

        appliedLayout = nil
        webView.cmuxApplyBrowserViewportLayout(nativeLayout)
        return true
    }

    func apply(_ layout: BrowserViewportLayout, updateWebView: Bool = true) {
        appliedLayout = layout
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = layout.mode == .native ? [.width, .height] : []
        // In emulated mode the host's frame is the small aspect-fitted presentation while
        // its bounds are the large logical viewport. NSView's autoresizing pass otherwise
        // rewrites the child WKWebView back to presentation pixels after every portal layout.
        // Native/inspector mode keeps normal child autoresizing for WebKit-managed geometry.
        autoresizesSubviews = layout.mode == .native

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !Self.rect(frame, approximatelyEquals: layout.frame) {
            frame = layout.frame
        }
        if !Self.rect(bounds, approximatelyEquals: layout.webViewBounds) {
            bounds = layout.webViewBounds
        }
        CATransaction.commit()

        if updateWebView {
            applyRawWebViewGeometryIfSafe()
        }
    }

    func matches(_ layout: BrowserViewportLayout, epsilon: CGFloat = 0.5) -> Bool {
        guard Self.rect(frame, approximatelyEquals: layout.frame, epsilon: epsilon),
              Self.rect(bounds, approximatelyEquals: layout.webViewBounds, epsilon: epsilon),
              autoresizingMask == (layout.mode == .native ? [.width, .height] : []),
              autoresizesSubviews == (layout.mode == .native) else {
            return false
        }
        guard let webView, webView.superview === self else { return true }
        return Self.rect(webView.frame, approximatelyEquals: bounds, epsilon: epsilon) &&
            Self.rect(webView.bounds, approximatelyEquals: bounds, epsilon: epsilon) &&
            webView.autoresizingMask == webView.cmuxBrowserViewportAutoresizingMask
    }

    override func layout() {
        super.layout()
        applyRawWebViewGeometryIfSafe()
    }

    private func applyRawWebViewGeometryIfSafe() {
        guard let webView, webView.superview === self else { return }
        guard !browserPortalHasVisibleWebKitCompanionSubview(for: webView) else { return }
        webView.cmuxApplyRawBrowserViewportGeometry(bounds)
    }

    private func hasActiveViewport(for webView: WKWebView) -> Bool {
        (webView as? CmuxWebView)?.browserViewportModel?.viewport != nil
    }

    private static func rect(
        _ lhs: CGRect,
        approximatelyEquals rhs: CGRect,
        epsilon: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= epsilon &&
            abs(lhs.minY - rhs.minY) <= epsilon &&
            abs(lhs.width - rhs.width) <= epsilon &&
            abs(lhs.height - rhs.height) <= epsilon
    }

}
