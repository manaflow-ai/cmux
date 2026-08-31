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
        let revision = FeedCoordinator.shared.store?.revision ?? 0
        let items = FeedCoordinator.shared.snapshot(pendingOnly: pendingOnly)

        // The phone Feed is a decision surface, not a raw event log: session
        // lifecycle rows carry no renderable content, and routine tool churn
        // (every PreToolUse/PostToolUse) would crowd the row cap out of the
        // rows a user can act on. Failed tool results stay — they are the
        // notable exceptions worth surfacing.
        let visibleItems = items.filter { item in
            switch item.kind {
            case .sessionStart, .sessionEnd, .toolUse:
                return false
            case .toolResult:
                if case .toolResult(_, _, let isError) = item.payload {
                    return isError
                }
                return false
            case .permissionRequest, .exitPlan, .question, .userPrompt,
                 .assistantMessage, .stop, .todos:
                return true
            }
        }

        // The store appends chronologically; encode the newest rows first so
        // the frame-fitting cut drops the oldest rows.
        var rows: [[String: Any]] = []
        rows.reserveCapacity(min(visibleItems.count, Self.mobileFeedMaximumItemCount))
        var resolvedTargets: [String: FeedJumpResolver.Target?] = [:]
        for item in visibleItems.suffix(Self.mobileFeedMaximumItemCount).reversed() {
            rows.append(mobileFeedRow(for: item, resolvedTargets: &resolvedTargets))
        }

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

    /// One wire row: the control-socket item encoding plus the mobile-only
    /// routing and context fields.
    private func mobileFeedRow(
        for item: WorkstreamItem,
        resolvedTargets: inout [String: FeedJumpResolver.Target?]
    ) -> [String: Any] {
        var dict = FeedSocketEncoding.itemDict(item)

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
            if let parsed = FeedJumpResolver.parse(item.workstreamId) {
                target = FeedJumpResolver.lookup(agent: parsed.agent, sessionId: parsed.sessionId)
            } else {
                target = nil
            }
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
