import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import WebKit

/// What an automation run of `cmux window|pane|tab screenshot` paints over
/// (``ScreenshotHandlers``). The app cannot reproduce the browser host's mask
/// of the secrets a page shows (vault, TOTP, typed secrets), so no browser
/// pixel leaves the app this way: a browser tab's whole area, every web view
/// the app does not own (a sidebar app, a link preview) and every Chromium
/// page window are painted opaque black. The app's own agent chat and page
/// tabs stay. A web view under no listed owner is masked, so a new kind of
/// web content fails closed. A page's pixels reach automation only through the
/// browser REPL, which masks them.
@MainActor
enum ScreenshotPrivacyMask {
    /// Whether `invocation`'s capture is masked: every run but a person's
    /// own. An app's run carries `user` during the person's gesture in it
    /// (``ActionInvocation/callerApp`` says whose), and an agent names its
    /// chat or terminal; those are masked too, so the image never reaches them.
    static func applies(to invocation: ActionInvocation) -> Bool {
        invocation.origin != .user || invocation.callerApp != nil || invocation.callerAgentSession != nil
            || invocation.callerTerminal != nil
    }

    /// The rectangles to paint over in `window`, in window coordinates.
    static func rects(in window: NSWindow, services: AppServices) -> [NSRect] {
        var rects: [NSRect] = []
        if let controller = services.windows.controllers.first(where: { $0.window === window }) {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                guard case .browser(let entry)? = pane.currentContent, entry.chrome.window === window,
                      !entry.chrome.isHiddenOrHasHiddenAncestor else { continue }
                rects.append(entry.chrome.convert(entry.chrome.bounds, to: nil))
            }
        }
        if let root = window.contentView { rects += foreignWebContentRects(in: root) }
        // Chromium draws its pages in child windows, at any depth, which the window server's image includes.
        for child in window.visibleChildWindows where WindowOverlayHost.isPageWindow(child) {
            rects.append(window.convertFromScreen(child.frame))
        }
        return rects.filter { $0.width > 0 && $0.height > 0 }
    }

    /// The shown web views under `root` that no app-owned view holds, in
    /// window coordinates. The agent chat (``AgentPaneView``) and page tabs
    /// (``InternalPageView``: Settings, Debug Settings) draw only the app's
    /// own UI.
    static func foreignWebContentRects(in root: NSView) -> [NSRect] {
        var rects: [NSRect] = []
        func visit(_ view: NSView) {
            // A hidden or transparent view hides its whole subtree on screen.
            guard !view.isHidden, view.alphaValue > 0 else { return }
            if isAppOwnedHost(view) { return }
            if view is WKWebView {
                rects.append(view.convert(view.bounds, to: nil))
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return rects.filter { $0.width > 0 && $0.height > 0 }
    }

    /// Whether an app-owned view (``foreignWebContentRects(in:)``) holds `view`.
    static func isAppOwned(_ view: NSView) -> Bool {
        sequence(first: view, next: \.superview).contains(where: isAppOwnedHost)
    }

    private static func isAppOwnedHost(_ view: NSView) -> Bool {
        view is AgentPaneView || view is InternalPageView
    }
}
