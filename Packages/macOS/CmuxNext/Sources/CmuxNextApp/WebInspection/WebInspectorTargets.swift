import AppKit
import CmuxNextFocus
import WebKit

/// Finds the web view the inspector commands act on (`WebInspectorTarget`).
///
/// The focused one first: the key window's first responder inside a web
/// view (a page, a Settings or popover window). Else the window's focus
/// below the palette (`FocusState.underlying`, what the palette's commands
/// act on), so the web view focused before Cmd-Shift-P stays the target: a
/// browser pane gives its tab (either engine), any other pane or a top page
/// gives the visible `WKWebView` inside it. Nil when no web view is
/// focused; the commands then show disabled.
@MainActor
struct WebInspectorTargets {
    /// The target in `controller`'s window, with `keyWindow`'s first responder.
    func target(in controller: WindowController?, keyWindow: NSWindow? = NSApp.keyWindow) -> WebInspectorTarget? {
        let focus = controller.map { Self.inspected($0.focus.state) } ?? FocusState.Resolved.none
        if let pane = focus.pane, let paneController = controller?.content?.paneController(key: pane) {
            if case .browser(let entry)? = paneController.currentContent { return .browser(entry.tab) }
            if let webView = Self.webView(containing: keyWindow?.firstResponder, within: paneController.view)
                ?? Self.webView(in: paneController.view) {
                return .webView(webView)
            }
        }
        if let responder = Self.webView(containing: keyWindow?.firstResponder, within: nil) { return .webView(responder) }
        if let controller, let route = controller.shownTopPage, let view = controller.topPages.views[route],
           let webView = Self.webView(in: view) {
            return .webView(webView)
        }
        return nil
    }

    /// What the commands act on: the target below the palette or another
    /// overlay, else the focus itself.
    static func inspected(_ state: FocusState) -> FocusState.Resolved {
        if case .overlay = state.resolved { return state.underlying }
        return state.resolved
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
