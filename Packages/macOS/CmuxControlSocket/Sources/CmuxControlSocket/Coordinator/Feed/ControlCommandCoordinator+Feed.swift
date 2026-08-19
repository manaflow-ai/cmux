internal import Foundation

/// The Feed domain (`feed.jump`, `feed.list`), lifted byte-faithfully from the
/// former `TerminalController.v2Feed*` bodies. Each payload is built
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries); the resulting Foundation object is identical, so the encoded
/// wire bytes match.
///
/// The worker-lane feed methods (`feed.push`, `feed.permission.reply`,
/// `feed.question.reply`, `feed.exit_plan.reply`) block or await on the socket
/// worker and remain on the app-side worker path — they are deliberately NOT
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

    /// Dispatches the nonisolated Feed worker methods. The explicit context
    /// parameter keeps the socket-worker path from touching the coordinator's
    /// main-actor state while allowing the app seam to perform its own
    /// off-main lookup.
    nonisolated func handleSocketWorkerFeed(
        _ request: ControlRequest,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult? {
        guard request.method == "feed.jump" else { return nil }
        return feedJump(request.params, context: context)
    }

    /// Dispatches the asynchronous `feed.jump` lookup. The socket worker
    /// waits for this result without making the filesystem read on its own
    /// thread; the app seam owns the background lookup boundary.
    public nonisolated func handleSocketWorkerFeedAsync(
        _ request: ControlRequest,
        context: (any ControlCommandContext)?
    ) async -> ControlCallResult? {
        guard request.method == "feed.jump" else { return nil }
        guard let workstreamID = rawString(request.params, "workstream_id") else {
            return .err(
                code: "invalid_params",
                message: "feed.jump requires workstream_id",
                data: nil
            )
        }
        let matched = await context?.controlFeedResolvePossibleSurfaceAsync(
            workstreamID: workstreamID
        ) ?? false
        return .ok(.object([
            "workstream_id": .string(workstreamID),
            "matched": .bool(matched),
        ]))
    }

    /// `feed.jump` — resolve whether a workstream id maps to a known surface.
    nonisolated func feedJump(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let workstreamID = rawString(params, "workstream_id") else {
            return .err(
                code: "invalid_params",
                message: "feed.jump requires workstream_id",
                data: nil
            )
        }
        // MVP: resolve to a cmux surface via `SessionIndexStore` lands in
        // the UI PR; for now we return whether the id is known so callers
        // can show a toast.
        let matched = context?.controlFeedResolvePossibleSurface(workstreamID: workstreamID) ?? false
        return .ok(.object([
            "workstream_id": .string(workstreamID),
            "matched": .bool(matched),
        ]))
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
