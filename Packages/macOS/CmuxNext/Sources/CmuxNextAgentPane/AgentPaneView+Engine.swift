public import AppKit
public import CmuxNextPages
import WebKit

// The pane's page in whichever engine shows it: on the shared page host (``PageWebView``) the page
// may show in Chromium, and ``AgentPaneView/webView`` is then a hidden WebKit view. Focus goes
// through ``AgentPaneView/focusChat()``, scripts through ``AgentPaneView/callPageScript(_:arguments:)``,
// pictures and the Chromium page's window through these.
extension AgentPaneView {
    /// The Chromium page that shows the chat now; nil on WebKit.
    public var chromiumPage: (any PageChromiumPage)? { page?.chromiumPage }

    /// A picture of the page as it draws now; nil when there is none.
    public func pageSnapshot() async -> NSImage? {
        if let page { return await page.snapshot() }
        return try? await webView.takeSnapshot(configuration: nil)
    }

    /// Whether `point` (screen coordinates) in `eventWindow` is on the Chromium page of this pane: a
    /// Chromium page draws in a child window of the pane's window, over its view.
    func chromiumPageContains(_ point: CGPoint, eventWindow: NSWindow?) -> Bool {
        guard let chromiumPage = page?.chromiumPage, let eventWindow, let window, eventWindow.parent === window,
              let frame = Self.screenFrame(of: chromiumPage.contentView) else { return false }
        return frame.contains(point)
    }

    private static func screenFrame(of view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}
