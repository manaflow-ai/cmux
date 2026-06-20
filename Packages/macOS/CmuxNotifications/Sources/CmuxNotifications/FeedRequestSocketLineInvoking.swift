/// Delivers a single newline-framed JSON-RPC line to the cmux control socket's
/// in-process handler, so a notification-feed request can drive the same V2
/// command path a socket client would.
///
/// Kept app-side because the only conformer forwards to the app-target
/// `TerminalController.shared.handleSocketLine(_:)` singleton, which the package
/// must not import. ``FeedRequestRouter`` builds the line (typed, see
/// ``FeedRequestSocketCommand``) and hands the finished string here; this seam
/// performs the side effect and discards the result, exactly as the legacy
/// `handleFeedRequestFocus`/`handleFeedRequestSendText` did (`_ = controller.handleSocketLine(line)`).
@MainActor
public protocol FeedRequestSocketLineInvoking: AnyObject {
    /// Routes one JSON-RPC line through the in-process socket handler. The result
    /// is intentionally ignored, mirroring the legacy fire-and-forget invoke.
    func invoke(line: String)
}
