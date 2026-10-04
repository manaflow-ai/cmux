public import Foundation

/// The web engine that shows a page.
public nonisolated enum PageHostEngine: String, Sendable {
    case webKit = "webkit"
    case cef
}

/// One message from a page, as the engine saw it. The engine fills the frame facts from its own
/// state, never from the page's payload, so the trust check can rely on them.
public struct PageHostMessage {
    /// The URL of the document that sent the message.
    public var frameURL: URL?
    /// True when the sender is the page's top-level document.
    public var isMainFrame: Bool
    /// The envelope, JSON-compatible.
    public var body: Any

    public init(frameURL: URL?, isMainFrame: Bool, body: Any) {
        self.frameURL = frameURL
        self.isMainFrame = isMainFrame
        self.body = body
    }
}

/// Answers one page message with the reply (a JSON-compatible object, or nil for none).
public typealias PageHostHandler = @MainActor (PageHostMessage) async -> Any?

/// The engine bridge of a page. Same shape as the agent pane's `PaneHostBridge` (branch
/// feat-cmux-next-pane-cef-bridge), so a CEF host implements it with the DevTools-protocol
/// binding: it carries page messages to native code and runs native pushes in the page.
/// It never handles keys: keys go through the app's one key dispatcher.
///
/// The page sees the same API on every engine:
/// `window.webkit.messageHandlers.cmuxPage.postMessage(envelope)` resolving to the reply, and
/// `window.__cmuxPageReceive(envelope)` for pushes.
@MainActor public protocol PageHostBridge: AnyObject {
    var engine: PageHostEngine { get }
    /// Starts sending page messages to `handler`. Call before the page loads.
    func install(_ handler: @escaping PageHostHandler)
    /// Runs `script` in the page's main frame, page world. Fire and forget.
    func evaluate(_ script: String)
    /// Stops answering; pending messages get no reply.
    func uninstall()
}
