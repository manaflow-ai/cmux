public import AppKit
public import CmuxNextPages

// The pane's page in whichever engine shows it: the page host's ``PageWebView`` may show it in
// Chromium, and ``PageWebView/webKitEngine`` is then nil. Focus goes
// through ``AgentPaneView/focusChat()``, scripts through ``AgentPaneView/callPageScript(_:arguments:)``,
// pictures and the Chromium page's window through these.
extension AgentPaneView {
    /// The Chromium page that shows the chat now; nil on WebKit.
    public var chromiumPage: (any PageChromiumPage)? { page.chromiumPage }

    /// A picture of the page as it draws now; nil when there is none.
    public func pageSnapshot() async -> NSImage? {
        await page.snapshot()
    }

    /// Whether ``pageSnapshot()`` can stand in for the page under a pane (``PageWebView/snapshotKeepsClearAreas``).
    public var snapshotKeepsClearAreas: Bool { page.snapshotKeepsClearAreas }

    /// Whether the page shows, or is to show, in Chromium. Chromium draws it in its own window over the
    /// pane, which a page kept clear (alpha 0) does not hide: a picture under it shows through its clear
    /// areas until the picture goes (the New Tab composer row drawn twice, 2026-10-24).
    public var pageDrawsOverCovers: Bool { page.engineDecision.engine == .cef }

    /// Whether `point` (screen coordinates) in `eventWindow` is on the Chromium page of this pane: a
    /// Chromium page draws in a child window of the pane's window, over its view.
    func chromiumPageContains(_ point: CGPoint, eventWindow: NSWindow?) -> Bool {
        guard let chromiumPage = page.chromiumPage, let eventWindow, let window, eventWindow.parent === window,
              let frame = Self.screenFrame(of: chromiumPage.contentView) else { return false }
        return frame.contains(point)
    }

    private static func screenFrame(of view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}
