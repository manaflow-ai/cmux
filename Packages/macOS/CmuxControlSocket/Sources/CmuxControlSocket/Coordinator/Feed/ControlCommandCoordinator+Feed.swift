internal import Foundation

/// The Feed domain (`feed.jump`, `feed.list`), lifted byte-faithfully from the
/// former `TerminalController.v2Feed*` bodies. Each payload is built
/// directly as a ``JSONValue`` (the typed twin of the legacy `[String: Any]`
/// dictionaries); the resulting Foundation object is identical, so the encoded
/// wire bytes match.
///
/// The blocking feed methods (`feed.push`, `feed.permission.reply`,
/// `feed.question.reply`, `feed.exit_plan.reply`) remain on the app-side worker
/// path. `feed.jump` has both synchronous and asynchronous entrypoints so the
/// in-process dispatcher and the real socket share the same response shape.
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

    /// Handles the synchronous worker-lane `feed.jump` call used by
    /// in-process socket-line callers. The app seam performs the legacy
    /// filesystem lookup off the main actor.
    public nonisolated func handleSocketWorkerFeed(
        _ request: ControlRequest,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult? {
        guard request.method == "feed.jump" else { return nil }
        guard let workstreamID = rawString(request.params, "workstream_id") else {
            return .err(
                code: "invalid_params",
                message: context?.controlFeedInvalidJumpMessage()
                    ?? String(
                        localized: "socket.feed.jump.invalidParams",
                        defaultValue: "feed.jump requires workstream_id"
                    ),
                data: nil
            )
        }
        let matched = context?.controlFeedResolvePossibleSurface(
            workstreamID: workstreamID
        ) ?? false
        return .ok(.object([
            "workstream_id": .string(workstreamID),
            "matched": .bool(matched),
        ]))
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
                message: context?.controlFeedInvalidJumpMessage()
                    ?? String(
                        localized: "socket.feed.jump.invalidParams",
                        defaultValue: "feed.jump requires workstream_id"
                    ),
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
