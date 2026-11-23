public import AppKit
import CmuxNextDesign
public import CmuxNextPages
import WebKit

// The pane's page in whichever engine shows it: on the shared page host (``PageWebView``) the page
// may show in Chromium, and ``AgentPaneView/webView`` is then a hidden WebKit view. Focus goes
// through ``AgentPaneView/focusChat()``, scripts through ``AgentPaneView/callPageScript(_:arguments:timeout:)``,
// pictures and the Chromium page's window through these.
extension AgentPaneView {
    /// The Chromium page that shows the chat now; nil on WebKit.
    public var chromiumPage: (any PageChromiumPage)? { page?.chromiumPage }

    /// The page shows in Chromium once its browser is made (``chromiumPage`` is nil until then).
    public var waitsForChromium: Bool {
        guard let page else { return false }
        return page.engineDecision.engine == .cef && !page.showsChromium
    }

    /// A picture of the page as it draws now; nil when there is none.
    public func pageSnapshot() async -> NSImage? {
        model.transport.beforePageWork?()
        if let page { return await page.snapshot() }
        return try? await webView.takeSnapshot(configuration: nil)
    }

    /// Whether ``pageSnapshot()`` can stand in for the page under a pane (``PageWebView/snapshotKeepsClearAreas``).
    public var snapshotKeepsClearAreas: Bool { page?.snapshotKeepsClearAreas ?? true }

    /// Whether the page shows, or is to show, in Chromium. Chromium draws it in its own window over the
    /// pane, which a page kept clear (alpha 0) does not hide: a picture under it shows through its clear
    /// areas until the picture goes (the New Tab composer row drawn twice, 2026-10-24).
    public var pageDrawsOverCovers: Bool { page?.engineDecision.engine == .cef }

    /// Whether `point` (screen coordinates) in `eventWindow` is on the Chromium page of this pane: a
    /// Chromium page draws in a child window of the pane's window, over its view.
    func chromiumPageContains(_ point: CGPoint, eventWindow: NSWindow?) -> Bool {
        guard let chromiumPage = page?.chromiumPage, let eventWindow, let window, eventWindow.parent === window, !isInALeavingPane,
              let frame = Self.screenFrame(of: chromiumPage.contentView) else { return false }
        return frame.contains(point)
    }

    /// The agent pane in `window` whose Chromium page shows in `page` (its child window): one whose page the app told Chromium to show (``PageWebView/chromiumShows``) and whose pane did not leave its layout (`isInALeavingPane`: a closed pane shows to the end of the close's move, with the pane that stays over it). A pane has more agent pages at the same place: hidden views, and in a paint hold a new view at alpha 0 above the one that still shows.
    public static func chromiumAgentPane(under page: NSWindow, in window: NSWindow) -> AgentPaneView? {
        let center = CGPoint(x: page.frame.midX, y: page.frame.midY)
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let pane = view as? AgentPaneView, pane.page?.chromiumShows == true, !pane.isInALeavingPane, let content = pane.chromiumPage?.contentView, let host = content.window,
               host.convertToScreen(content.convert(content.bounds, to: nil)).contains(center) { return pane }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The Chromium page window (a child of `window`) that takes `window`'s held keys: the key window
    /// when it is one, else the window of a shown agent page in Chromium whose view has the
    /// keyboard in its own window (it was focused while the app was not active).
    public static func chromiumPageWindow(in window: NSWindow) -> NSWindow? {
        if let key = NSApp.keyWindow, key !== window, key.parent === window { return key }
        guard window.firstResponder === window || window.firstResponder == nil else { return nil }
        // The condition below is a copy by hand of 1 of the 3 parts of ``isShownToPerson`` (not drawn away); the finder has the 2 others in its own form (a view of this window, a page that the app told Chromium to show). A new part of that property does not come here by itself.
        return window.childWindows?.first { child in
            child.isVisible && chromiumAgentPane(under: child, in: window).map { $0.page?.isDrawnAway != true } == true // not a page that is drawn away (it keeps its place and its last frame)
        }
    }

    private static func screenFrame(of view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}
