import CMUXAgentLaunch
import CMUXMobileCore
import Foundation

/// Mobile-host agent-feed verbs: `feed.list` mirrors the Mac's workstream
/// Feed to a paired phone, enriched with the resolved workspace/surface
/// target and display titles so the phone can render provenance and route
/// replies without extra RPCs. The reply verbs (`feed.permission.reply`,
/// `feed.question.reply`, `feed.exit_plan.reply`) are dispatched to the same
/// handlers the local control socket uses, so every entrypoint resolves
/// pending items through `FeedCoordinator.deliverReply`.
extension TerminalController {
    /// Reads only retained Feed content on this authenticated Mac. No paths,
    /// terminal input, or remote-relay access are accepted by this method.
    func v2MobileFeedText(params: [String: Any]) -> V2CallResult {
        guard let rawID = params["item_id"] as? String,
              let id = UUID(uuidString: rawID),
              let offset = params["offset"] as? Int, offset >= 0 else {
            return .err(code: "invalid_params", message: "Expected item_id and a nonnegative offset", data: nil)
        }
        let item = FeedCoordinator.shared.snapshot(pendingOnly: false).first(where: { $0.id == id })
        let notification = item == nil
            ? TerminalNotificationStore.shared.notificationFeedHistory.notifications.first(where: { $0.id == id })
            : nil
        guard item != nil || notification != nil else {
            return .err(code: "not_found", message: "Feed item is no longer available", data: nil)
        }
        let version = (item?.updatedAt ?? notification!.createdAt).timeIntervalSinceReferenceDate
        if offset > 0, (params["version"] as? Double) != version {
            return .err(code: "stale_item", message: "Feed item changed while reading", data: nil)
        }
        let fullText = item?.fullText ?? [notification!.title, notification!.subtitle, notification!.body]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard let page = WorkstreamTextPage(text: fullText, offset: offset) else {
            return .err(code: "invalid_params", message: "Invalid text offset", data: nil)
        }
        var result: [String: Any] = ["text": page.text, "version": version]
        if let next = page.nextOffset { result["next_offset"] = next }
        return .ok(result)
    }

    private nonisolated static let mobileFeedResponseByteLimit =
        MobileSyncFrameCodec.defaultMaximumFrameByteCount - (64 * 1024)
    private nonisolated static let mobileFeedMaximumItemCount = 200
    private nonisolated static let mobileFeedContextByteLimit = 2_048
    private nonisolated static let mobileFeedMetadataByteLimit = 512

    /// Returns the Mac's workstream feed, newest first, with mobile
    /// enrichment. The phone merges snapshots from all connected Macs.
    func v2MobileFeedList(
        params: [String: Any],
        responseID: String? = "feed.list"
    ) async -> V2CallResult {
        let pendingOnly = params["pending_only"] as? Bool ?? false
        let workstreamRevision = FeedCoordinator.shared.store?.revision ?? 0
        let notificationHistory = TerminalNotificationStore.shared.notificationFeedHistory
        notificationHistory.reconcileActiveNotifications(TerminalNotificationStore.shared.notifications)
        let notificationSnapshot = notificationHistory.snapshot
        let revision = FeedCoordinator.combinedMobileFeedRevision(
            workstream: workstreamRevision,
            notifications: notificationSnapshot.revision
        )
        let items = FeedCoordinator.shared.snapshot(pendingOnly: pendingOnly)

        // The phone Feed is a decision surface, not a raw event log: session
        // lifecycle rows carry no renderable content, routine tool churn
        // (every PreToolUse/PostToolUse) would crowd the row cap out of the
        // rows a user can act on, and the user's own prompts are not news to
        // the user — they surface as the quoted context line under agent
        // rows instead. Failed tool results stay — they are the notable
        // exceptions worth surfacing.
        let visibleItems = items.filter { item in
            switch item.kind {
            case .sessionStart, .sessionEnd, .toolUse, .userPrompt:
                return false
            case .toolResult:
                if case .toolResult(_, _, let isError) = item.payload {
                    return isError
                }
                return false
            case .permissionRequest, .exitPlan, .question,
                 .assistantMessage, .stop, .todos:
                return true
            }
        }

        // The store appends chronologically; encode the newest rows first so
        // the frame-fitting cut drops the oldest rows.
        var datedRows: [(date: Date, id: String, row: [String: Any])] = []
        datedRows.reserveCapacity(min(
            visibleItems.count + notificationSnapshot.notifications.count,
            Self.mobileFeedMaximumItemCount
        ))
        var resolvedTargets: [String: FeedJumpResolver.Target?] = [:]
        let workstreamIDs = Set(visibleItems.map { $0.id })
        for item in visibleItems {
            datedRows.append((item.createdAt, item.id.uuidString, mobileFeedRow(for: item, resolvedTargets: &resolvedTargets)))
        }
        if !pendingOnly {
            for notification in notificationSnapshot.notifications
            where !workstreamIDs.contains(notification.id) {
                datedRows.append((notification.createdAt, notification.id.uuidString, mobileNotificationFeedRow(notification)))
            }
        }
        datedRows.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
        let rows = datedRows.prefix(Self.mobileFeedMaximumItemCount).map(\.row)

        let fittedRows = await Self.mobileFeedRowsFittingFrame(
            responseID: responseID,
            revision: revision,
            rows: rows
        )
        return .ok([
            "revision": revision,
            "items": fittedRows,
        ])
    }

    private func mobileNotificationFeedRow(
        _ notification: NotificationFeedHistoryRecord
    ) -> [String: Any] {
        let fullText = [notification.title, notification.subtitle, notification.body]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        var row: [String: Any] = [
            "id": notification.id.uuidString,
            "event_id": notification.id.uuidString,
            "workstream_id": "notification-\(notification.id.uuidString)",
            "source": "notification",
            "kind": "assistantMessage",
            "status": "telemetry",
            "created_at": ISO8601DateFormatter().string(from: notification.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: notification.createdAt),
            "title": notification.title,
            "text": fullText,
            "workspace_id": notification.tabId.uuidString,
            "full_text_preview": fullText,
            "full_text_truncated": false,
        ]
        if let surfaceID = notification.surfaceId {
            row["surface_id"] = surfaceID.uuidString
        }
        return row
    }

    /// One wire row: the control-socket item encoding plus the mobile-only
    /// routing and context fields.
    private func mobileFeedRow(
        for item: WorkstreamItem,
        resolvedTargets: inout [String: FeedJumpResolver.Target?]
    ) -> [String: Any] {
        var dict = FeedSocketEncoding.itemDict(item)
        // `id` is the durable event identity. Keep an explicit alias in the
        // mobile contract so a reply can name the exact event without
        // overloading request IDs (which only exist for blocking prompts).
        dict["event_id"] = item.id.uuidString
        if let reply = item.reply {
            dict["reply_text"] = Self.mobileFeedString(
                reply.text,
                limitedToUTF8Bytes: Self.mobileFeedContextByteLimit
            )
            dict["replied_at"] = ISO8601DateFormatter().string(from: reply.createdAt)
        }

        // The control-socket encoding ships the agent's raw ExitPlanMode tool
        // input (a JSON envelope). The phone renders plan text, never wire
        // JSON, so send the same parsed plan body the Mac Feed panel shows.
        if case .exitPlan(_, let plan, _) = item.payload {
            dict["plan"] = Self.mobileFeedString(
                WorkstreamExitPlanPreview(rawPlan: plan).planText,
                limitedToUTF8Bytes: 8_000
            )
            dict.removeValue(forKey: "plan_truncated")
        }

        let target: FeedJumpResolver.Target?
        if let cached = resolvedTargets[item.workstreamId] {
            target = cached
        } else {
            target = FeedJumpResolver.resolve(item.workstreamId)
            resolvedTargets[item.workstreamId] = target
        }
        if let target {
            dict["workspace_id"] = target.workspaceId
            dict["surface_id"] = target.surfaceId
            if let workspaceID = UUID(uuidString: target.workspaceId),
               let workspace = AppDelegate.shared?
                   .tabManagerFor(tabId: workspaceID)?
                   .workspacesById[workspaceID] {
                dict["workspace_title"] = Self.mobileFeedString(
                    workspace.title,
                    limitedToUTF8Bytes: Self.mobileFeedMetadataByteLimit
                )
                if let surfaceID = UUID(uuidString: target.surfaceId),
                   let surfaceTitle = workspace.panelTitle(panelId: surfaceID) {
                    dict["surface_title"] = Self.mobileFeedString(
                        surfaceTitle,
                        limitedToUTF8Bytes: Self.mobileFeedMetadataByteLimit
                    )
                }
            }
        }

        if let context = item.context {
            var contextDict: [String: Any] = [:]
            if let value = context.lastUserMessage {
                contextDict["last_user_message"] = Self.mobileFeedString(
                    value, limitedToUTF8Bytes: Self.mobileFeedContextByteLimit
                )
            }
            if let value = context.assistantPreamble {
                contextDict["assistant_preamble"] = Self.mobileFeedString(
                    value, limitedToUTF8Bytes: Self.mobileFeedContextByteLimit
                )
            }
            if let value = context.planSummary {
                contextDict["plan_summary"] = Self.mobileFeedString(
                    value, limitedToUTF8Bytes: Self.mobileFeedContextByteLimit
                )
            }
            if let value = context.toolSummary {
                contextDict["tool_summary"] = Self.mobileFeedString(
                    value, limitedToUTF8Bytes: Self.mobileFeedContextByteLimit
                )
            }
            if let value = context.permissionMode {
                contextDict["permission_mode"] = Self.mobileFeedString(
                    value, limitedToUTF8Bytes: Self.mobileFeedMetadataByteLimit
                )
            }
            if !contextDict.isEmpty {
                dict["context"] = contextDict
            }
        }
        // Reading metadata is independent of layout truncation on the phone.
        // Keep a canonical preview so the row and the reader describe the same text.
        let readingText = item.fullText
        let readingPreview = Self.mobileFeedString(readingText, limitedToUTF8Bytes: 8_000)
        dict["full_text_preview"] = readingPreview
        dict["full_text_truncated"] = readingPreview != readingText
        return dict
    }

    private nonisolated static func mobileFeedRowsFittingFrame(
        responseID: String?,
        revision: Int,
        rows: [[String: Any]]
    ) async -> [[String: Any]] {
        let worker = Task.detached(priority: .utility) {
            mobileFeedRowsFittingFrameOnWorker(
                responseID: responseID,
                revision: revision,
                rows: rows
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func mobileFeedRowsFittingFrameOnWorker(
        responseID: String?,
        revision: Int,
        rows: [[String: Any]]
    ) -> [[String: Any]] {
        guard !Task.isCancelled, !rows.isEmpty else { return [] }

        let emptyPayload: [String: Any] = [
            "revision": revision,
            "items": [],
        ]
        let emptyEncoded = MobileHostRPCEnvelope.encodeResponse(
            id: responseID,
            result: .ok(emptyPayload)
        )
        let emptyResponseByteCount = emptyEncoded.count
        guard emptyResponseByteCount <= mobileFeedResponseByteLimit else { return [] }

        var responseByteCount = emptyResponseByteCount - 2
        var fittedCount = 0
        for row in rows {
            guard !Task.isCancelled else {
                return Array(rows.prefix(fittedCount))
            }
            guard JSONSerialization.isValidJSONObject(row),
                  let encoded = try? JSONSerialization.data(withJSONObject: row) else {
                break
            }
            let separatorByteCount = fittedCount == 0 ? 0 : 1
            let remainingByteCount = mobileFeedResponseByteLimit
                - responseByteCount
                - separatorByteCount
            guard encoded.count <= remainingByteCount else { break }
            responseByteCount += separatorByteCount + encoded.count
            fittedCount += 1
        }
        guard fittedCount < rows.count else { return rows }
        return Array(rows.prefix(fittedCount))
    }

    private nonisolated static func mobileFeedString(
        _ value: String,
        limitedToUTF8Bytes maxBytes: Int
    ) -> String {
        guard maxBytes >= 0, value.utf8.count > maxBytes else { return value }
        var byteCount = 0
        var endIndex = value.startIndex
        while endIndex < value.endIndex {
            let nextIndex = value.index(after: endIndex)
            let characterByteCount = value[endIndex..<nextIndex].utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            byteCount += characterByteCount
            endIndex = nextIndex
        }
        return String(value[..<endIndex])
    }
}
