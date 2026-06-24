public import WebKit
public import AppKit

/// Closes any open WebKit Web Inspector windows for a window, a set of windows, or
/// a single web view.
///
/// cmux opens Web Inspector through WebKit's private `_inspector` object because the
/// deployable SDK surface exposes no stable close API. Teardown stays on that same
/// auditable SPI path (via ``WKWebView/cmuxInspectorObject()`` and the
/// `cmuxCall*` trampolines) so WebKit unregisters the inspector window observers
/// before the parent AppKit close cascade runs. Construct one and call it; the
/// service holds no state.
@MainActor
public struct WebInspectorTeardownService {
    public init() {}

    /// Closes every open inspector for web views reachable from `window`'s content
    /// view tree. Returns the number of inspectors actually closed.
    @discardableResult
    public func closeAllInspectors(in window: NSWindow) -> Int {
        assert(Thread.isMainThread)

        return webViews(in: window).reduce(0) { count, webView in
            closeInspector(for: webView) ? count + 1 : count
        }
    }

    /// Closes every open inspector across all `windows`. Returns the total closed.
    @discardableResult
    public func closeAllInspectors(in windows: [NSWindow]) -> Int {
        windows.reduce(0) { count, window in
            count + closeAllInspectors(in: window)
        }
    }

    /// Closes the inspector for a single `webView` if one is open. Returns `true`
    /// when an inspector was closed, `false` when none was open or it was the
    /// inspector's own frontend web view.
    @discardableResult
    public func closeInspector(for webView: WKWebView) -> Bool {
        assert(Thread.isMainThread)

        guard !isInspectorFrontendWebView(webView),
              let inspector = webView.cmuxInspectorObject() else {
            return false
        }

        let isVisibleSelector = NSSelectorFromString("isVisible")
        let isAttachedSelector = NSSelectorFromString("isAttached")
        let isVisible = inspector.cmuxCallBool(selector: isVisibleSelector)
        let isAttached = inspector.cmuxCallBool(selector: isAttachedSelector)
        let shouldClose = (isVisible == true)
            || (isAttached == true)
            || (isVisible == nil && isAttached == nil)
        guard shouldClose else { return false }

        // cmux already opens Web Inspector through WebKit's `_inspector` object
        // because the deployable SDK surface does not expose a stable close API.
        // Keep teardown on the same auditable SPI path so WebKit unregisters the
        // inspector window observers before the parent AppKit close cascade runs.
        let closeSelector = NSSelectorFromString("close")
        guard inspector.responds(to: closeSelector) else { return false }
        inspector.cmuxCallVoid(selector: closeSelector)
        return true
    }

    private func webViews(in window: NSWindow) -> [WKWebView] {
        var seen = Set<ObjectIdentifier>()
        var result: [WKWebView] = []
        let roots = [window.contentView, window.contentView?.superview].compactMap { $0 }
        for root in roots {
            collectWebViews(in: root, seen: &seen, result: &result)
        }
        return result
    }

    private func collectWebViews(
        in view: NSView,
        seen: inout Set<ObjectIdentifier>,
        result: inout [WKWebView]
    ) {
        if let webView = view as? WKWebView,
           !isInspectorFrontendWebView(webView) {
            let id = ObjectIdentifier(webView)
            if !seen.contains(id) {
                seen.insert(id)
                result.append(webView)
            }
        }

        for subview in view.subviews {
            collectWebViews(in: subview, seen: &seen, result: &result)
        }
    }

    private func isInspectorFrontendWebView(_ webView: WKWebView) -> Bool {
        webView.cmuxIsWebInspectorObject
    }
}

extension NSObject {
    /// Invokes a zero-argument, `Bool`-returning ObjC method via a
    /// `@convention(c)` trampoline. Returns `nil` when the receiver does not
    /// respond to the selector.
    ///
    /// Sanctioned C-trampoline exception: WebKit's inspector SPI is reached by
    /// selector, so the bool/void accessors must be invoked through an explicit
    /// function-pointer cast rather than a typed Swift call.
    public func cmuxCallBool(selector: Selector) -> Bool? {
        guard responds(to: selector) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        return fn(self, selector)
    }

    /// Invokes a zero-argument, `Void`-returning ObjC method via a
    /// `@convention(c)` trampoline; no-op when the receiver does not respond.
    ///
    /// Sanctioned C-trampoline exception, as for ``cmuxCallBool(selector:)``.
    public func cmuxCallVoid(selector: Selector) {
        guard responds(to: selector) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
    }
}
