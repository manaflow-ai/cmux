public import AppKit
public import CmuxNextPages
import WebKit

// The pane's page in whichever engine shows it: on the shared page host (``PageWebView``) the page
// may show in Chromium, and ``AgentPaneView/webView`` is then a hidden WebKit view. Everything that
// focuses, reads or pictures the page goes through these, never through `webView` directly.
extension AgentPaneView {
    /// The view that takes the keyboard when the page is focused: Chromium's view or the WebKit view.
    public var focusView: NSView { page?.focusView ?? webView }

    /// The Chromium page that shows the chat now; nil on WebKit.
    public var chromiumPage: (any PageChromiumPage)? { page?.chromiumPage }

    /// Gives the page the keyboard (a Chromium page takes it in its own window).
    ///
    /// - Returns: Whether the page took it (always true for a Chromium page, which takes it async).
    @discardableResult
    public func focusPage() -> Bool {
        if let page, page.showsChromium {
            page.focusPage()
            return true
        }
        guard let window else { return false }
        if window.firstResponder === webView { return true }
        return window.makeFirstResponder(webView)
    }

    /// Runs `body` as an async function of `arguments` (named) in the page, in whichever engine shows
    /// it, and returns its JSON-shaped value; nil when it threw or returned nothing.
    ///
    /// - Parameters:
    ///   - body: The function body; it may `await` and `return`.
    ///   - arguments: Its named arguments (JSON-shaped values).
    /// - Returns: The returned value, or nil.
    public func pageFunction(_ body: String, arguments: [String: Any] = [:]) async -> Any? {
        if let page { return await page.callPageFunction(body, arguments: arguments) }
        return try? await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

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
