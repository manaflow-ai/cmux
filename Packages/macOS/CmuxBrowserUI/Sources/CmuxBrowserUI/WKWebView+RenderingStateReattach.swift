public import WebKit
public import AppKit
import ObjectiveC
#if DEBUG
internal import CMUXDebugLog
#endif

/// Storage key for the per-``WKWebView`` "needs rendering-state reattach" flag,
/// kept as an associated object because ``WKWebView`` has no stored property to
/// add one to.
private nonisolated(unsafe) var cmuxBrowserPanelNeedsRenderingStateReattachKey: UInt8 = 0

extension NSObject {
    /// Invokes a zero-argument, `void`-returning Objective-C selector by name if
    /// the receiver responds to it, returning whether it was invoked.
    ///
    /// Used to drive private AppKit/WebKit view-lifecycle selectors
    /// (`viewDidUnhide`, `_enterInWindow`, `viewDidHide`, `_exitInWindow`, …)
    /// that have no public Swift API.
    @discardableResult
    func browserPanelCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }

    /// Whether this object is part of the Web Inspector frontend, detected by
    /// class name (`WKInspector` / `WebInspector`).
    ///
    /// Inlined here so the rendering-state reattach extension is self-contained
    /// and does not depend on an app-side predicate. The check is purely a
    /// class-name string match, so it folds onto ``NSObject`` directly.
    var cmuxBrowserPanelIsWebInspectorObject: Bool {
        String.cmuxBrowserPanelIsWebInspectorClassName(String(describing: type(of: self)))
            || String.cmuxBrowserPanelIsWebInspectorClassName(NSStringFromClass(type(of: self)))
    }
}

extension String {
    /// Whether a class name belongs to the Web Inspector frontend.
    ///
    /// The Inspector's `WKWebView` and its host views must skip the
    /// hide/show rendering-state lifecycle pokes, otherwise the inspector pane
    /// flickers or detaches.
    static func cmuxBrowserPanelIsWebInspectorClassName(_ className: String) -> Bool {
        className.contains("WKInspector") || className.contains("WebInspector")
    }
}

extension WKWebView {
    /// Backing flag: set when the panel hides the web view, consumed when it is
    /// shown again to know a rendering-state reattach is owed.
    private var cmuxBrowserPanelNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, &cmuxBrowserPanelNeedsRenderingStateReattachKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxBrowserPanelNeedsRenderingStateReattachKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Whether this web view currently owes a rendering-state reattach because
    /// it was hidden while off-window.
    public var cmuxBrowserPanelRequiresRenderingStateReattach: Bool {
        cmuxBrowserPanelNeedsRenderingStateReattach
    }

    /// Whether this web view is the Web Inspector frontend, which must be
    /// excluded from the hide/show lifecycle pokes.
    public var cmuxBrowserPanelIsInspectorFrontend: Bool {
        cmuxBrowserPanelIsWebInspectorObject
    }

    /// Stable opaque identity string for a web view, used only in DEBUG logs.
    private static func cmuxBrowserPanelObjectID(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    /// Compact `"x,y wxh"` description of a rect, used only in DEBUG logs.
    private static func cmuxBrowserPanelRectDescription(_ rect: NSRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    private func cmuxBrowserPanelApplyRenderingStateRefresh(
        reason: String,
        force: Bool
    ) {
        guard !cmuxBrowserPanelIsInspectorFrontend else {
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.localHost.webview.skipInspectorLifecycle " +
                "web=\(Self.cmuxBrowserPanelObjectID(self)) reason=\(reason)"
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
                "web=\(Self.cmuxBrowserPanelObjectID(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(Self.cmuxBrowserPanelRectDescription(frame))"
            )
        }
#endif
    }

    /// Marks the web view as hidden and fires the private "view left window"
    /// lifecycle selectors so WebKit pauses its rendering pipeline.
    public func cmuxBrowserPanelNotifyHidden(reason: String) {
        guard !cmuxBrowserPanelIsInspectorFrontend else {
#if DEBUG
            CMUXDebugLog.logDebugEvent(
                "browser.localHost.webview.skipInspectorHidden " +
                "web=\(Self.cmuxBrowserPanelObjectID(self)) reason=\(reason)"
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
                "browser.localHost.webview.hidden web=\(Self.cmuxBrowserPanelObjectID(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    /// Reattaches rendering state only if a hide previously marked it owed.
    public func cmuxBrowserPanelReattachRenderingState(reason: String) {
        cmuxBrowserPanelApplyRenderingStateRefresh(reason: reason, force: false)
    }

    /// Unconditionally reattaches rendering state regardless of the owed flag.
    public func cmuxBrowserPanelForceRenderingStateRefresh(reason: String) {
        cmuxBrowserPanelApplyRenderingStateRefresh(reason: reason, force: true)
    }
}
