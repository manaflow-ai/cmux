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
/// keeps the stale layer tree from the hidden host. A first-sized reveal also
/// delivers a real geometry delta so WebKit recomputes scrollable content.

private var cmuxBrowserPortalNeedsRenderingStateReattachKey: UInt8 = 0
private var cmuxBrowserPortalNeedsFirstSizedRevealNudgeKey: UInt8 = 0
private var cmuxBrowserPortalFirstSizedRevealNudgeGenerationKey: UInt8 = 0

#if DEBUG
private func browserPortalRenderingStateDebugToken(_ view: NSView?) -> String {
    guard let view else { return "nil" }
    let ptr = Unmanaged.passUnretained(view).toOpaque()
    return String(describing: ptr)
}

private func browserPortalRenderingStateDebugFrame(_ frame: NSRect) -> String {
    String(
        format: "%.1f,%.1f %.1fx%.1f",
        frame.origin.x,
        frame.origin.y,
        frame.size.width,
        frame.size.height
    )
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
    private static func browserPortalRectApproximatelyEqual(
        _ lhs: NSRect,
        _ rhs: NSRect,
        epsilon: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

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

    fileprivate var browserPortalNeedsFirstSizedRevealNudge: Bool {
        get {
            (objc_getAssociatedObject(self, &cmuxBrowserPortalNeedsFirstSizedRevealNudgeKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxBrowserPortalNeedsFirstSizedRevealNudgeKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    fileprivate var browserPortalFirstSizedRevealNudgeGeneration: UInt64 {
        get {
            (objc_getAssociatedObject(self, &cmuxBrowserPortalFirstSizedRevealNudgeGenerationKey) as? NSNumber)?
                .uint64Value ?? 0
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxBrowserPortalFirstSizedRevealNudgeGenerationKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var browserPortalRequiresRenderingStateReattach: Bool {
        browserPortalNeedsRenderingStateReattach
    }

    var browserPortalRequiresFirstSizedRevealNudge: Bool {
        browserPortalNeedsFirstSizedRevealNudge
    }

    func browserPortalMarkNeedsFirstSizedRevealNudge(reason: String) {
        browserPortalNeedsFirstSizedRevealNudge = true
#if DEBUG
        cmuxDebugLog(
            "browser.portal.webview.firstSizedReveal.flag web=\(browserPortalRenderingStateDebugToken(self)) " +
            "reason=\(reason) window=\(window == nil ? 0 : 1) frame=\(browserPortalRenderingStateDebugFrame(frame))"
        )
#endif
    }

    func browserPortalMarkFirstSizedRevealNudgeIfNavigationStartsWithoutPresentation(reason: String) {
        // An attached window only counts as presenting when it is ordered on
        // screen with nonzero alpha; an ordered-out or alpha-0 host loads the
        // document just as hidden as no window at all.
        let startsInHiddenWindow = window.map { $0.alphaValue <= 0.01 || !$0.isVisible } ?? false
        guard window == nil ||
            startsInHiddenWindow ||
            !frame.size.width.isFinite ||
            !frame.size.height.isFinite ||
            frame.width <= 1 ||
            frame.height <= 1 else {
            return
        }
        browserPortalMarkNeedsFirstSizedRevealNudge(reason: reason)
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
        browserPortalMarkNeedsFirstSizedRevealNudge(reason: reason)
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

    @discardableResult
    func browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
        reason: String,
        hasCompanionWKSubviews: Bool,
        managedByExternalFullscreenWindow: Bool
    ) -> Bool {
        guard browserPortalNeedsFirstSizedRevealNudge else { return false }
        guard let window else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=noWindow frame=\(browserPortalRenderingStateDebugFrame(frame))"
            )
#endif
            return false
        }
        // An ordered-out, miniaturized, or alpha-0 window is not a genuine
        // presentation: WebKit still treats the webview as hidden, so consuming
        // the one-shot flag here would waste it. Keep the nudge pending for the
        // refresh pass that runs once the window actually presents.
        guard window.isVisible, window.alphaValue > 0.01 else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=windowNotPresented frame=\(browserPortalRenderingStateDebugFrame(frame))"
            )
#endif
            return false
        }
        guard frame.size.width.isFinite,
              frame.size.height.isFinite,
              frame.width > 1,
              frame.height > 1 else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=tinyFrame frame=\(browserPortalRenderingStateDebugFrame(frame))"
            )
#endif
            return false
        }
        guard !hasCompanionWKSubviews else {
            browserPortalNeedsFirstSizedRevealNudge = false
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=companionWKSubviews frame=\(browserPortalRenderingStateDebugFrame(frame))"
            )
#endif
            return false
        }
        guard !managedByExternalFullscreenWindow else {
            browserPortalNeedsFirstSizedRevealNudge = false
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=externalFullscreen frame=\(browserPortalRenderingStateDebugFrame(frame))"
            )
#endif
            return false
        }

        let originalFrame = frame
        let originalSize = originalFrame.size
        let nudgedSize = NSSize(width: originalSize.width, height: max(1, originalSize.height - 1))
        let nudgedFrame = NSRect(origin: originalFrame.origin, size: nudgedSize)
        guard !Self.browserPortalRectApproximatelyEqual(originalFrame, nudgedFrame) else {
            browserPortalNeedsFirstSizedRevealNudge = false
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=noDelta frame=\(browserPortalRenderingStateDebugFrame(frame))"
            )
#endif
            return false
        }

        browserPortalNeedsFirstSizedRevealNudge = false
        browserPortalFirstSizedRevealNudgeGeneration &+= 1
        let generation = browserPortalFirstSizedRevealNudgeGeneration

#if DEBUG
        cmuxDebugLog(
            "browser.portal.webview.firstSizedReveal.nudge web=\(browserPortalRenderingStateDebugToken(self)) " +
            "reason=\(reason) old=\(browserPortalRenderingStateDebugFrame(originalFrame)) " +
            "nudge=\(browserPortalRenderingStateDebugFrame(nudgedFrame))"
        )
#endif

        setFrameSize(nudgedSize)
        needsLayout = true
        layoutSubtreeIfNeeded()
        enclosingScrollView?.layoutSubtreeIfNeeded()
        displayIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.browserPortalFirstSizedRevealNudgeGeneration == generation else { return }
            guard self.window != nil else {
#if DEBUG
                cmuxDebugLog(
                    "browser.portal.webview.firstSizedReveal.restore.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                    "reason=\(reason) skip=noWindow"
                )
#endif
                return
            }
            guard Self.browserPortalRectApproximatelyEqual(self.frame, nudgedFrame) else {
#if DEBUG
                cmuxDebugLog(
                    "browser.portal.webview.firstSizedReveal.restore.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                    "reason=\(reason) skip=frameChanged current=\(browserPortalRenderingStateDebugFrame(self.frame)) " +
                    "expected=\(browserPortalRenderingStateDebugFrame(nudgedFrame))"
                )
#endif
                return
            }
            self.setFrameSize(originalSize)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            self.enclosingScrollView?.layoutSubtreeIfNeeded()
            self.displayIfNeeded()
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.restore web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) frame=\(browserPortalRenderingStateDebugFrame(self.frame))"
            )
#endif
        }
        return true
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

// MARK: - Navigation-start marking

extension WKWebView {
    /// Starts a request load, first arming the first-sized-reveal nudge when
    /// the navigation begins without a genuine presentation (no window, an
    /// unpresented window, or a degenerate frame).
    @discardableResult
    func browserPortalLoadMarkingFirstSizedRevealNudge(_ request: URLRequest) -> WKNavigation? {
        browserPortalMarkFirstSizedRevealNudgeIfNavigationStartsWithoutPresentation(
            reason: "navigationStart:\(request.url?.scheme?.lowercased() ?? "none")"
        )
        return load(request)
    }

    /// File-URL variant of `browserPortalLoadMarkingFirstSizedRevealNudge(_:)`.
    @discardableResult
    func browserPortalLoadFileMarkingFirstSizedRevealNudge(
        _ url: URL,
        allowingReadAccessTo readAccessURL: URL
    ) -> WKNavigation? {
        browserPortalMarkFirstSizedRevealNudgeIfNavigationStartsWithoutPresentation(
            reason: "navigationStart:\(url.scheme?.lowercased() ?? "none")"
        )
        return loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }

    /// Docks the webview into an alpha-0 background-preload host view and
    /// records the hidden rendering state (WebKit re-enter reattach plus the
    /// first-sized-reveal geometry nudge) that the reveal path replays.
    func browserPortalDockIntoHiddenPreloadHost(_ hostContentView: NSView, reason: String) {
        frame = hostContentView.bounds
        autoresizingMask = [.width, .height]
        hostContentView.addSubview(self)
        browserPortalNotifyHidden(reason: "backgroundPreload:\(reason)")
    }
}

// MARK: - Companion WebKit subview detection

extension WindowBrowserSlotView {
    /// Companion WebKit subviews (find bars, inspector overlays, PiP shims)
    /// own their own geometry inside the slot; rendering-state passes must not
    /// reset or nudge the primary webview frame while one is visible.
    func hasVisibleWebKitCompanionSubview(for primaryWebView: WKWebView) -> Bool {
        var stack = subviews.filter { $0 !== primaryWebView }
        while let current = stack.popLast() {
            if current.isDescendant(of: primaryWebView) {
                continue
            }
            if current.isHidden || current.alphaValue <= 0 {
                continue
            }
            if String(describing: type(of: current)).contains("WK") {
                let width = max(current.frame.width, current.bounds.width)
                let height = max(current.frame.height, current.bounds.height)
                if width > 1, height > 1 {
                    return true
                }
                continue
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }
}
