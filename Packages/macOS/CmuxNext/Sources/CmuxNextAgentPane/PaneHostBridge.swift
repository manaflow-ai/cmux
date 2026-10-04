public import Foundation

/// The web engine that shows a pane page.
public nonisolated enum PaneHostEngine: String, Sendable {
    case webKit = "webkit"
    case cef
}

/// One request from a pane page, as the engine saw it. The engine fills
/// the frame facts from its own state, never from the page's payload, so
/// the trust check can rely on them.
public struct PaneHostMessage {
    /// The URL of the document that sent the request.
    public var frameURL: URL?
    /// True when the sender is the top-level document of the pane.
    public var isMainFrame: Bool
    /// The request object (`{id, method, params}`), JSON-compatible.
    public var body: Any

    public init(frameURL: URL?, isMainFrame: Bool, body: Any) {
        self.frameURL = frameURL
        self.isMainFrame = isMainFrame
        self.body = body
    }
}

/// Answers one page request with the reply envelope
/// (``AgentPaneReply``: `{ok, value}` or `{ok: false, error}`).
public typealias PaneHostHandler = @MainActor (PaneHostMessage) async -> [String: Any]

/// The engine bridge of a pane page (spec "Engines"). It does only two
/// things: it carries page requests to native code (the handshake, which
/// delivers the endpoint and token, and native UI ops such as tab open or
/// dictation), and it runs native pushes in the page (theme, shortcuts
/// display). Everything else (the data plane) goes directly from the page to
/// its provider and never passes through the bridge.
///
/// The bridge never handles keys: a pane's key handling goes through the
/// app's single key dispatcher.
///
/// The page sees the same API on every engine:
/// `window.webkit.messageHandlers.<name>.postMessage(body)` resolving to the
/// reply, so `webviews/src/agent-session` needs no engine checks.
@MainActor public protocol PaneHostBridge: AnyObject {
    var engine: PaneHostEngine { get }
    /// Starts sending page requests to `handler`. Call before the page
    /// loads: requests of a page that loaded first are not seen.
    func install(_ handler: @escaping PaneHostHandler) async throws
    /// Runs `script` in the page's main frame, main world. Fire and forget.
    func evaluate(_ script: String)
    /// Stops answering; pending requests get no reply.
    func uninstall()
}

/// The trust rule of every engine: only the pane's own top-level page may
/// talk to the host (the handshake carries the daemon token).
public enum PaneHostTrust {
    public static func isTrusted(_ message: PaneHostMessage, source: AgentPaneSource) -> Bool {
        message.isMainFrame && source.isTrusted(message.frameURL)
    }
}
