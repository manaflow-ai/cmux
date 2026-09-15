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

/// Identifies a real Web Inspector companion without treating every WebKit
/// view as an inspector. macOS 27 can add visible WebKit-like siblings to a
/// page view, and preserving the page frame for those siblings clips browser
/// content at the pane edge.
@MainActor
enum BrowserWebInspectorCompanionDetector {
    static func containsVisibleInspectorCompanion(in host: NSView, primaryWebView: WKWebView) -> Bool {
        let primaryFrame = host.convert(primaryWebView.bounds, from: primaryWebView)
        var stack = host.subviews.filter { $0 !== primaryWebView }
        while let current = stack.popLast() {
            guard !current.isDescendant(of: primaryWebView), !current.isHidden, current.alphaValue > 0 else {
                continue
            }
            let currentFrame = host.convert(current.bounds, from: current)
            guard currentFrame.width > 1, currentFrame.height > 1 else { continue }
            if cmuxIsWebInspectorObject(current) ||
                isDockedInspectorWebView(current, currentFrame: currentFrame, primaryFrame: primaryFrame) {
                return true
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    private static func isDockedInspectorWebView(
        _ view: NSView,
        currentFrame: NSRect,
        primaryFrame: NSRect
    ) -> Bool {
        guard view is WKWebView else { return false }
        return isSideDockedFrame(currentFrame, primaryFrame: primaryFrame) ||
            isVerticallyDockedFrame(currentFrame, primaryFrame: primaryFrame)
    }

    private static func isSideDockedFrame(_ currentFrame: NSRect, primaryFrame: NSRect) -> Bool {
        guard verticalOverlap(between: primaryFrame, and: currentFrame) > 8 else { return false }
        return HostedInspectorDockSide.resolve(pageFrame: primaryFrame, inspectorFrame: currentFrame) != nil
    }

    private static func isVerticallyDockedFrame(
        _ currentFrame: NSRect,
        primaryFrame: NSRect,
        epsilon: CGFloat = 1
    ) -> Bool {
        let smallerWidth = min(primaryFrame.width, currentFrame.width)
        guard smallerWidth > 1 else { return false }
        guard horizontalOverlap(between: primaryFrame, and: currentFrame) > smallerWidth * 0.7 else {
            return false
        }
        return currentFrame.maxY <= primaryFrame.minY + epsilon ||
            primaryFrame.maxY <= currentFrame.minY + epsilon
    }

    private static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    private static func horizontalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    }
}

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
    private static func browserPortalSizeApproximatelyEqual(
        _ lhs: NSSize,
        _ rhs: NSSize,
        epsilon: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon &&
            abs(lhs.height - rhs.height) <= epsilon
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

    private(set) var browserPortalNeedsFirstSizedRevealNudge: Bool {
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
        let startsInHiddenWindow = window.map {
            !$0.isVisible || $0.isMiniaturized || $0.alphaValue <= 0.01
        } ?? false
        guard window == nil ||
            startsInHiddenWindow ||
            isHiddenOrHasHiddenAncestor ||
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
        guard !cmuxIsWebInspectorObject(self) else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.hidden.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=inspectorFrontend"
            )
#endif
            return
        }
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
        companionSearchRoot: NSView,
        relativeTo expectedWindow: NSWindow?
    ) -> Bool {
        guard browserPortalNeedsFirstSizedRevealNudge else { return false }
        return browserPortalApplyFirstSizedRevealGeometryNudgeIfNeeded(
            reason: reason,
            hasCompanionWKSubviews: companionSearchRoot.browserPortalHasVisibleWebKitCompanionSubview(for: self),
            managedByExternalFullscreenWindow: cmuxIsManagedByExternalFullscreenWindow(relativeTo: expectedWindow)
        )
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
        guard window.isVisible, !window.isMiniaturized, window.alphaValue > 0.01 else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=hiddenWindow frame=\(browserPortalRenderingStateDebugFrame(frame))"
            )
#endif
            return false
        }
        guard !isHiddenOrHasHiddenAncestor else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.firstSizedReveal.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=hiddenView frame=\(browserPortalRenderingStateDebugFrame(frame))"
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
        guard !Self.browserPortalSizeApproximatelyEqual(originalSize, nudgedSize) else {
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.browserPortalFirstSizedRevealNudgeGeneration == generation else { return }
            guard Self.browserPortalSizeApproximatelyEqual(self.frame.size, nudgedSize) else {
#if DEBUG
                cmuxDebugLog(
                    "browser.portal.webview.firstSizedReveal.restore.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                    "reason=\(reason) skip=sizeChanged current=\(browserPortalRenderingStateDebugFrame(self.frame)) " +
                    "expectedSize=\(String(format: "%.1fx%.1f", nudgedSize.width, nudgedSize.height))"
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

    private func browserPortalApplyRenderingStateRefresh(reason: String, force: Bool) {
        guard !cmuxIsWebInspectorObject(self) else {
#if DEBUG
            cmuxDebugLog(
                "browser.portal.webview.reattach.skip web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) skip=inspectorFrontend"
            )
#endif
            return
        }
        guard force || browserPortalNeedsRenderingStateReattach else { return }
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
                "\(force ? "browser.portal.webview.forceRefresh" : "browser.portal.webview.reattach") " +
                "web=\(browserPortalRenderingStateDebugToken(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(String(format: "%.1f,%.1f %.1fx%.1f", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height))"
            )
        }
#endif
    }

    func browserPortalReattachRenderingState(reason: String) {
        browserPortalApplyRenderingStateRefresh(reason: reason, force: false)
    }

    func browserPortalForceRenderingStateRefresh(reason: String) {
        browserPortalApplyRenderingStateRefresh(reason: reason, force: true)
    }
}

extension NSView {
    func browserPortalHasVisibleWebKitCompanionSubview(for primaryWebView: WKWebView) -> Bool {
        BrowserWebInspectorCompanionDetector.containsVisibleInspectorCompanion(
            in: self,
            primaryWebView: primaryWebView
        )
    }
}
