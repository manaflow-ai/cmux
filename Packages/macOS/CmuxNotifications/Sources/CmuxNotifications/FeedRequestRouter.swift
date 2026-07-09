public import Observation

/// Translates notification-feed focus and send-text requests into V2 control
/// socket commands, so the feed drives the same code path a socket client would
/// without binding to `TerminalController`. Lifted verbatim from `AppDelegate`'s
/// `handleFeedRequestFocus`/`handleFeedRequestSendText` bodies, with the inline
/// `JSONSerialization` payloads replaced by typed ``FeedRequestSocketCommand``
/// values and the `TerminalController.shared.handleSocketLine(_:)` calls routed
/// through the injected ``FeedRequestSocketLineInvoking`` seam.
///
/// A Coordinator (CONVENTIONS §2): it sequences a request into one or more
/// commands and owns no I/O itself. `@MainActor` because both feed requests
/// arrive on the main `NotificationCenter` selector path and the socket invoke
/// is a main-actor side effect. The app-target `@objc` selector methods stay on
/// `AppDelegate` (selectors cannot move into a package) and forward their parsed
/// `userInfo` here.
@MainActor
@Observable
public final class FeedRequestRouter {
    private let socketInvoking: any FeedRequestSocketLineInvoking

    /// Creates the router over the socket-line seam.
    public init(socketInvoking: any FeedRequestSocketLineInvoking) {
        self.socketInvoking = socketInvoking
    }

    /// Focuses the feed's target surface: select its workspace, focus the
    /// surface, then flash the focus ring. Mirrors `handleFeedRequestFocus`.
    ///
    /// The flash uses the same visual as cmd+shift+H / Flash Focused Panel so the
    /// user's eye is pulled to the terminal content the feed jumped to.
    public func routeFocus(workspaceId: String, surfaceId: String) {
        invoke(.init(method: "workspace.select", params: ["workspace_id": workspaceId]))
        invoke(.init(method: "surface.focus", params: ["surface_id": surfaceId]))
        invoke(.init(method: "surface.trigger_flash", params: ["surface_id": surfaceId]))
    }

    /// Sends `text` to the feed's target surface as one atomic `surface.send_text`.
    /// Mirrors `handleFeedRequestSendText`: terminal-mode Return is CR, and one
    /// `send_text` is atomic, so the CR is appended directly to the text rather
    /// than issued as a separate `sendNamedKey "Return"`.
    public func routeSendText(surfaceId: String, text: String) {
        invoke(.init(method: "surface.send_text", params: [
            "surface_id": surfaceId,
            "text": text + "\r",
        ]))
    }

    private func invoke(_ command: FeedRequestSocketCommand) {
        guard let line = command.jsonLine() else { return }
        socketInvoking.invoke(line: line)
    }
}
