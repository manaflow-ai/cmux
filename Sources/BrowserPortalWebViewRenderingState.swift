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

/// Resolves the primary page-content child of a macOS `WKWebView` without
/// depending on WebKit's sibling ordering. Inspector/companion children are
/// excluded explicitly. WebKit's structural page child (normally
/// `WKFlippedView`) is preferred when present; otherwise a unique child
/// covering the largest portion of the web view wins. Near-ties fail closed
/// rather than being disambiguated by focus.
extension WKWebView {
    func cmuxBrowserPageContentRoot(owningResponder: NSResponder? = nil) -> NSView? {
        let candidates = subviews.filter {
            !$0.isHidden && $0.alphaValue > 0 && !cmuxIsWebInspectorObject($0)
        }
        let webBounds = bounds
        let webArea = max(webBounds.width * webBounds.height, 1)
        guard !candidates.isEmpty,
              webBounds.width > 0,
              webBounds.height > 0 else {
            return nil
        }
        let structuralCandidates = candidates.filter { $0.cmuxBrowserIsPageContentCandidate }
        let candidatePool = structuralCandidates.isEmpty ? candidates : structuralCandidates

        guard candidatePool.count > 1 else {
            guard let candidate = candidatePool.first else { return nil }

            // A recognized WebKit page child remains authoritative while it is
            // being resized or temporarily covered by a companion view. The
            // responder ownership check still prevents an unknown sibling from
            // being treated as page content.
            if !structuralCandidates.isEmpty {
                if let owningResponder {
                    guard let responderView = owningResponder.cmuxBrowserOwningView() else {
                        return nil
                    }
                    guard responderView === self
                            || responderView === candidate
                            || responderView.isDescendant(of: candidate) else {
                        return nil
                    }
                }
                return candidate
            }

            let intersection = candidate.frame.intersection(webBounds)
            let coverage = max(0, intersection.width) * max(0, intersection.height) / webArea
            guard coverage >= 0.5 else { return nil }
            if let owningResponder {
                guard let responderView = owningResponder.cmuxBrowserOwningView() else {
                    return nil
                }
                guard responderView === candidate || responderView.isDescendant(of: candidate) else {
                    return nil
                }
            }
            return candidate
        }

        let scored = candidatePool.map { view in
            let intersection = view.frame.intersection(webBounds)
            let area = max(0, intersection.width) * max(0, intersection.height)
            return (view: view, coverage: area / webArea)
        }
        guard let maximumCoverage = scored.map(\.coverage).max(), maximumCoverage > 0 else {
            return nil
        }

        let winners = scored.filter { abs($0.coverage - maximumCoverage) <= 0.01 }
        guard winners.count == 1 else { return nil }

        if structuralCandidates.isEmpty {
            // Unknown siblings must cover the web view like real page content
            // before they can be treated as the page root.
            guard maximumCoverage >= 0.5 else { return nil }
        }
        if let owningResponder {
            guard let responderView = owningResponder.cmuxBrowserOwningView() else {
                return nil
            }
            // A responder in a clearly smaller sibling is browser chrome. Do
            // not use responder ownership to break a near-tie: an unknown
            // full-size WebKit companion/overlay must remain fail-closed.
            guard responderView === self
                    || responderView === winners[0].view
                    || responderView.isDescendant(of: winners[0].view) else {
                return nil
            }
        }
        return winners[0].view
    }

    /// Whether WebKit has not yet exposed a stable page-content structure.
    /// Ambiguous populated hierarchies remain fail-closed; a lone unknown
    /// child that is still being sized is the only populated transient case.
    var cmuxBrowserPageContentStructureIsTransient: Bool {
        let candidates = subviews.filter {
            !$0.isHidden && $0.alphaValue > 0 && !cmuxIsWebInspectorObject($0)
        }
        guard bounds.width > 0, bounds.height > 0 else {
            return true
        }
        if candidates.contains(where: { $0.cmuxBrowserIsPageContentCandidate }) {
            return false
        }
        guard candidates.count == 1 else {
            return candidates.isEmpty
        }
        let webArea = bounds.width * bounds.height
        let intersection = candidates[0].frame.intersection(bounds)
        let coverage = max(0, intersection.width) * max(0, intersection.height) / webArea
        return coverage < 0.5
    }
}

/// Returns the nearest view that owns a responder for browser focus routing.
/// Field editors use their tracked owner first; all other responder
/// chains are bounded so a malformed chain cannot add unbounded key-path work.
extension NSResponder {
    func cmuxBrowserOwningView() -> NSView? {
        if let fieldEditor = self as? NSTextView, fieldEditor.isFieldEditor {
            if let trackedOwner = cmuxTrackedFindFieldEditorOwner(fieldEditor) {
                return trackedOwner
            }
            var current: NSResponder? = fieldEditor.nextResponder
            var hops = 0
            while let next = current, hops < 64 {
                if let view = next as? NSView {
                    return view
                }
                current = next.nextResponder
                hops += 1
            }
            // A shared field editor's superview is a hosting detail, not an
            // ownership contract. If its tracked owner and bounded responder
            // chain do not identify a view, fail closed rather than assigning
            // focus to an unrelated browser sibling.
            return nil
        }

        if let view = self as? NSView {
            return view
        }
        var current: NSResponder? = self
        var hops = 0
        while let next = current, hops < 64 {
            if let view = next as? NSView {
                return view
            }
            current = next.nextResponder
            hops += 1
        }
        return nil
    }
}

/// Whether a direct WebKit child is the structural page-content host rather
/// than a companion/overlay. These private WebKit class names are the stable
/// AppKit ownership signal available on supported macOS releases; geometry is
/// retained as a compatibility fallback for future class-name changes.
private extension NSView {
    var cmuxBrowserIsPageContentCandidate: Bool {
        let classNames = [
            String(describing: type(of: self)),
            NSStringFromClass(type(of: self)),
        ]
        return classNames.contains { className in
            className == "WKFlippedView"
                || className == "WKContentView"
                || className == "WKScrollView"
        }
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
        var stack = subviews.filter { $0 !== primaryWebView }
        while let current = stack.popLast() {
            if current === primaryWebView || current.isDescendant(of: primaryWebView) {
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
