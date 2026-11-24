import AppKit
import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextPages
import WebKit

/// Finds the web view the inspector commands act on (`WebInspectorTarget`).
///
/// The focused one first: the key window's first responder inside a web
/// view (a page, a Settings or popover window). Else the window's focus
/// below the palette (`FocusState.underlying`, what the palette's commands
/// act on), so the web view focused before Cmd-Shift-P stays the target: a
/// browser pane gives its tab (either engine), any other pane or a top page
/// gives the visible cmux page inside it, in WebKit or in Chromium. Nil when
/// no web view is focused; the commands then show disabled.
///
/// cmux's own pages count only while `appPages` is on (`developerTools.appPages`), and never one
/// that refuses probes (``CmuxNextPages/PageWebView/refusesProbes``, a revealed password).
@MainActor
struct WebInspectorTargets {
    /// Whether cmux's own pages are targets (Settings > Advanced > Developer Tools for cmux Pages).
    var appPages = true

    /// The target in `controller`'s window, with `keyWindow`'s first responder.
    func target(in controller: WindowController?, keyWindow: NSWindow? = NSApp.keyWindow) -> WebInspectorTarget? {
        let focus = controller.map { Self.inspected($0.focus.state) } ?? FocusState.Resolved.none
        if let pane = focus.pane, let paneController = controller?.content?.paneController(key: pane) {
            if case .browser(let entry)? = paneController.currentContent { return .browser(entry.tab) }
            guard appPages else { return nil }
            if let page = Self.page(containing: keyWindow?.firstResponder, within: paneController.view)
                ?? Self.page(in: paneController.view) {
                return page
            }
        }
        guard appPages else { return nil }
        if let responder = Self.page(containing: keyWindow?.firstResponder, within: nil) { return responder }
        if let controller, let route = controller.shownTopPage, let view = controller.topPages.views[route],
           let page = Self.page(in: view) {
            return page
        }
        return nil
    }

    /// What the commands act on: the target below the palette or another
    /// overlay, else the focus itself.
    static func inspected(_ state: FocusState) -> FocusState.Resolved {
        if case .overlay = state.resolved { return state.underlying }
        return state.resolved
    }

    /// The target `view` shows when it is a page view: a cmux page (``PageWebView``) in Chromium
    /// gives its Chromium tab and in WebKit its web view; a page that refuses probes gives none.
    /// - Returns: Nil when `view` is no page; `.some(nil)` for a page that is not a target.
    static func target(of view: NSView) -> WebInspectorTarget?? {
        if let page = view as? PageWebView {
            if page.refusesProbes { return .some(nil) }
            if page.showsChromium {
                guard let tab = (page.chromiumPage as? CEFPageChromiumPage)?.tab else { return .some(nil) }
                return .chromiumPage(tab)
            }
            return .webView(page.webKitView)
        }
        if let webView = view as? WKWebView { return .webView(webView) }
        return nil
    }

    /// The page that holds `responder` (itself or an ancestor view), when it is inside `root` (any
    /// view when nil). The outermost page view counts: a cmux page's own web view is inside it.
    static func page(containing responder: NSResponder?, within root: NSView?) -> WebInspectorTarget? {
        var found: (view: NSView, target: WebInspectorTarget?)?
        var view = responder as? NSView
        while let current = view {
            if let target = target(of: current) { found = (current, target) }
            view = current.superview
        }
        guard let found, root.map({ found.view.isDescendant(of: $0) }) ?? true else { return nil }
        return found.target
    }

    /// The first shown page inside `root` (itself included), depth first.
    static func page(in root: NSView) -> WebInspectorTarget? {
        guard !root.isHidden, root.alphaValue > 0 else { return nil }
        if let target = target(of: root) {
            if case .webView(let webView)? = target, webView.bounds.isEmpty { return nil }
            return target
        }
        for subview in root.subviews {
            if let page = page(in: subview) { return page }
        }
        return nil
    }

    /// The web view that holds `responder` (itself or an ancestor view),
    /// when it is inside `root` (any view when nil).
    static func webView(containing responder: NSResponder?, within root: NSView?) -> WKWebView? {
        var view = responder as? NSView
        while let current = view {
            if let webView = current as? WKWebView {
                return (root.map { webView.isDescendant(of: $0) } ?? true) ? webView : nil
            }
            view = current.superview
        }
        return nil
    }

    /// The first shown web view inside `root` (itself included), depth first.
    static func webView(in root: NSView) -> WKWebView? {
        guard !root.isHidden, root.alphaValue > 0 else { return nil }
        if let webView = root as? WKWebView { return webView.bounds.isEmpty ? nil : webView }
        for subview in root.subviews {
            if let webView = webView(in: subview) { return webView }
        }
        return nil
    }
}
