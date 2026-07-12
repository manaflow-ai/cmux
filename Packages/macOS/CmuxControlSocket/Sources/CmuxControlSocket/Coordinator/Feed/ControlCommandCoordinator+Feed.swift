internal import Foundation

/// The main-actor feed domain (`feed.list`), lifted byte-faithfully from the
/// former `TerminalController.v2Feed*` body. Each payload is built
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries); the resulting Foundation object is identical, so the encoded
/// wire bytes match.
///
/// The worker-lane feed methods (`feed.push`, `feed.permission.reply`,
/// `feed.question.reply`, `feed.exit_plan.reply`, `feed.jump`) block, await, or
/// read hook state on the socket worker and remain on the app-side worker path.
/// They are deliberately NOT
/// dispatched here.
extension ControlCommandCoordinator {
    /// Dispatches the feed methods this coordinator owns; returns `nil` for
    /// anything else so the core `handle(_:)` can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a feed method.
    func handleFeed(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "feed.list":
            return feedList(request.params)
        default:
            return nil
        }
    }

    /// `feed.list` — snapshot the workstream feed items.
    func feedList(_ params: [String: JSONValue]) -> ControlCallResult {
        // Legacy used a plain `params["pending_only"] as? Bool`, so only a real
        // JSON boolean counts; anything else (including coercible strings/numbers)
        // falls back to `false`.
        let pendingOnly: Bool
        if case .bool(let value)? = params["pending_only"] {
            pendingOnly = value
        } else {
            pendingOnly = false
        }
        let items = context?.controlFeedSnapshotItems(pendingOnly: pendingOnly) ?? []
        return .ok(.object(["items": .array(items)]))
    }
}
