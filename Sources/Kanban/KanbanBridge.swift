import Foundation

/// Wire contract constants for the Kanban web bridge.
///
/// The webview posts requests to `window.webkit.messageHandlers.kanban` and the
/// native side pushes events back via `window.cmuxKanbanBridge.receive(...)`.
/// The board uses a dedicated handler (not the shared `agentSession` one) so its
/// message surface stays isolated from the agent session bridge.
enum KanbanBridgeContract {
    /// The `WKScriptMessageHandlerWithReply` name registered for the board.
    static let handlerName = "kanban"
}
