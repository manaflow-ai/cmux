public import WebKit
internal import ObjectiveC
#if DEBUG
internal import CMUXDebugLog
#endif

/// Rendering-state reattachment lifecycle for browser-panel-hosted `WKWebView`s.
///
/// When a local-host browser webview is hidden (its inline slot collapses) and
/// later re-shown, AppKit can leave the view in a deferred / unhosted rendering
/// state so it renders blank until something forces it back into the window
/// lifecycle. This extension drives that reattachment by replaying the private
/// `viewDidHide` / `viewDidUnhide` / `_enterInWindow` / `_exitInWindow` AppKit
/// selectors and invalidating layout/display, tracking whether a reattach is
/// pending via an objc associated object stored on the webview itself.
///
/// Web inspector frontends are exempt: their own window lifecycle must not be
/// poked. The caller supplies that predicate as `isInspectorFrontend` (typically
/// `NSObject.isCmuxWebInspectorObject`), so this lifecycle stays decoupled from
/// the inspector-detection seam.
extension WKWebView {
    private static let cmuxBrowserPanelRenderingStateReattachAssociationKey = malloc(1)!

    private var cmuxBrowserPanelNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, Self.cmuxBrowserPanelRenderingStateReattachAssociationKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                Self.cmuxBrowserPanelRenderingStateReattachAssociationKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Whether a rendering-state reattach is currently pending for this webview
    /// (set by a prior ``cmuxBrowserPanelNotifyHidden(reason:isInspectorFrontend:)``).
    public var cmuxBrowserPanelRequiresRenderingStateReattach: Bool {
        cmuxBrowserPanelNeedsRenderingStateReattach
    }

    private func cmuxBrowserPanelApplyRenderingStateRefresh(
        reason: String,
        force: Bool,
        isInspectorFrontend: Bool
    ) {
        guard !isInspectorFrontend else {
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.localHost.webview.skipInspectorLifecycle " +
                "web=\(browserPanelRenderingStateLogID) reason=\(reason)"
            )
#endif
            return
        }
        guard force || cmuxBrowserPanelNeedsRenderingStateReattach else { return }
        guard window != nil else { return }
        cmuxBrowserPanelNeedsRenderingStateReattach = false

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPanelCallVoidIfAvailable($0)
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
            CMUXDebugLog.logDebugEvent(
                "\(force ? "browser.localHost.webview.forceRefresh" : "browser.localHost.webview.reattach") " +
                "web=\(browserPanelRenderingStateLogID) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(frame.browserPanelRenderingStateLogDescription)"
            )
        }
#endif
    }

    /// Marks the webview as needing a rendering-state reattach and replays the
    /// private `viewDidHide` / `_exitInWindow` AppKit selectors so the view
    /// exits the window lifecycle cleanly when its inline slot is hidden.
    public func cmuxBrowserPanelNotifyHidden(reason: String, isInspectorFrontend: Bool) {
        guard !isInspectorFrontend else {
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.localHost.webview.skipInspectorHidden " +
                "web=\(browserPanelRenderingStateLogID) reason=\(reason)"
            )
#endif
            return
        }
        cmuxBrowserPanelNeedsRenderingStateReattach = true
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPanelCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            CMUXDebugLog.logDebugEvent(
                "browser.localHost.webview.hidden web=\(browserPanelRenderingStateLogID) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    /// Reattaches the webview's rendering state, but only if a reattach is
    /// pending. No-op for inspector frontends.
    public func cmuxBrowserPanelReattachRenderingState(reason: String, isInspectorFrontend: Bool) {
        cmuxBrowserPanelApplyRenderingStateRefresh(reason: reason, force: false, isInspectorFrontend: isInspectorFrontend)
    }

    /// Forces a rendering-state refresh regardless of whether a reattach was
    /// pending, used when the host knows the webview must redraw now. No-op for
    /// inspector frontends.
    public func cmuxBrowserPanelForceRenderingStateRefresh(reason: String, isInspectorFrontend: Bool) {
        cmuxBrowserPanelApplyRenderingStateRefresh(reason: reason, force: true, isInspectorFrontend: isInspectorFrontend)
    }
}

/// Window-portal variant of the rendering-state reattach lifecycle.
///
/// `BrowserWindowPortal` hosts browser webviews directly under the window (above
/// SwiftUI content) rather than in an inline panel slot. When such a portal-hosted
/// webview is hidden and later re-shown it hits the same AppKit deferred-rendering
/// blank-view problem as the panel path, so it replays the same private
/// `viewDidHide` / `viewDidUnhide` / `_enterInWindow` / `_exitInWindow` selectors
/// and invalidates layout/display. It tracks its pending-reattach flag under its
/// own associated-object key, independent of the panel path, and (unlike the panel
/// variant) does not gate on web-inspector frontends.
extension WKWebView {
    private static let cmuxBrowserPortalRenderingStateReattachAssociationKey = malloc(1)!

    private var browserPortalNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, Self.cmuxBrowserPortalRenderingStateReattachAssociationKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                Self.cmuxBrowserPortalRenderingStateReattachAssociationKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Whether a rendering-state reattach is currently pending for this
    /// portal-hosted webview (set by a prior ``browserPortalNotifyHidden(reason:)``).
    public var browserPortalRequiresRenderingStateReattach: Bool {
        browserPortalNeedsRenderingStateReattach
    }

    /// Marks the portal-hosted webview as needing a rendering-state reattach and
    /// replays the private `viewDidHide` / `_exitInWindow` AppKit selectors so the
    /// view exits the window lifecycle cleanly when its portal slot is hidden.
    public func browserPortalNotifyHidden(reason: String) {
        browserPortalNeedsRenderingStateReattach = true
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPanelCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            CMUXDebugLog.logDebugEvent(
                "browser.portal.webview.hidden web=\(browserPanelRenderingStateLogID) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    /// Reattaches the portal-hosted webview's rendering state, but only if a
    /// reattach is pending and the view is currently in a window.
    public func browserPortalReattachRenderingState(reason: String) {
        guard browserPortalNeedsRenderingStateReattach else { return }
        guard window != nil else { return }
        browserPortalNeedsRenderingStateReattach = false

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPanelCallVoidIfAvailable($0)
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
            CMUXDebugLog.logDebugEvent(
                "browser.portal.webview.reattach web=\(browserPanelRenderingStateLogID) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(frame.browserPanelRenderingStateLogDescription)"
            )
        }
#endif
    }
}

private extension NSObject {
    /// Invokes a nullary `Void`-returning Objective-C selector by name when the
    /// receiver responds to it, returning whether the call was dispatched.
    @discardableResult
    func browserPanelCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }
}

#if DEBUG
private extension WKWebView {
    /// Opaque pointer-identity string for the webview, used only in debug logs.
    var browserPanelRenderingStateLogID: String {
        String(describing: Unmanaged.passUnretained(self).toOpaque())
    }
}

private extension NSRect {
    /// Compact `x,y wxh` description used only in debug logs.
    var browserPanelRenderingStateLogDescription: String {
        String(format: "%.1f,%.1f %.1fx%.1f", origin.x, origin.y, width, height)
    }
}
#endif
