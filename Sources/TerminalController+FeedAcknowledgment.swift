import CMUXAgentLaunch
import Foundation

extension TerminalController {
    /// Reconciles and inserts one authoritative batch, then publishes it off the main-actor hop.
    nonisolated func v2IngestAcknowledgedFeedEvents(
        _ events: [WorkstreamEvent]
    ) -> V2CallResult {
        let ingestion = v2MainSync { () -> FeedBatchIngestion in
            guard FeedCoordinator.shared.store != nil else { return .unavailable }
            let authoritativeEvents: [WorkstreamEvent]
            switch FeedCoordinator.shared.resolveDeliveryTarget(for: events) {
            case .accepted(let events):
                authoritativeEvents = events
            case .notFound:
                return .notFound
            case .unavailable:
                return .unavailable
            }

            var itemIds: [UUID] = []
            itemIds.reserveCapacity(authoritativeEvents.count)
            for event in authoritativeEvents {
                v2ApplyIMessageModeSideEffects(for: event)
                guard let itemId = FeedCoordinator.shared.ingestRevalidatedOnMainActor(event) else {
                    continue
                }
                itemIds.append(itemId)
            }
            if itemIds.count == authoritativeEvents.count {
                v2NoteCoalescedFeedTranscriptEvents(authoritativeEvents)
            } else {
                return .unavailable
            }
            return .accepted(events: authoritativeEvents, itemIds: itemIds)
        }

        let authoritativeEvents: [WorkstreamEvent]
        let authoritativeItemIds: [UUID]
        switch ingestion {
        case .accepted(let events, let itemIds):
            authoritativeEvents = events
            authoritativeItemIds = itemIds
        case .notFound:
            return v2FeedTargetNotFound()
        case .unavailable:
            return v2FeedTargetUnavailable()
        }

        for (event, itemId) in zip(authoritativeEvents, authoritativeItemIds) {
            CmuxEventBus.shared.publishWorkstreamEvent(event, phase: "received")
            let result = FeedCoordinator.IngestBlockingResult.acknowledged(itemId: itemId)
            CmuxEventBus.shared.publishWorkstreamEvent(
                event,
                phase: "completed",
                result: FeedSocketEncoding.payload(for: result)
            )
        }

        let itemIds = authoritativeItemIds.map(\.uuidString)
        var payload: [String: Any]
        if itemIds.count == 1, let itemId = itemIds.first {
            payload = [
                "status": "acknowledged",
                "item_id": itemId,
            ]
        } else {
            payload = [
                "status": "acknowledged",
                "item_ids": itemIds,
            ]
        }
        v2AppendFeedTarget(from: authoritativeEvents.first, to: &payload)
        return .ok(payload)
    }

    @MainActor
    private func v2NoteCoalescedFeedTranscriptEvents(_ events: [WorkstreamEvent]) {
        guard let agentChatTranscriptService else { return }

        var pendingPiPostToolEvent: WorkstreamEvent?
        for event in events {
            if event.source == "pi", event.hookEventName == .postToolUse {
                if pendingPiPostToolEvent?.sessionId == event.sessionId {
                    pendingPiPostToolEvent = event
                    continue
                }
                if let pendingPiPostToolEvent {
                    agentChatTranscriptService.noteHookEvent(pendingPiPostToolEvent)
                }
                pendingPiPostToolEvent = event
                continue
            }

            if let pending = pendingPiPostToolEvent {
                agentChatTranscriptService.noteHookEvent(pending)
                pendingPiPostToolEvent = nil
            }
            agentChatTranscriptService.noteHookEvent(event)
        }
        if let pendingPiPostToolEvent {
            agentChatTranscriptService.noteHookEvent(pendingPiPostToolEvent)
        }
    }

    /// Publishes and inserts one Feed event from one authoritative live-target snapshot.
    nonisolated func v2IngestFeedEvent(
        _ event: WorkstreamEvent,
        waitTimeout: TimeInterval
    ) -> V2CallResult {
        let waitsForDecision = waitTimeout > 0 && event.requestId != nil
        let acceptedEvent = waitsForDecision ? UnsafeAuthoritativeFeedEventSlot() : nil
        let result = FeedCoordinator.shared.ingestBlocking(
            event: event,
            waitTimeout: waitTimeout,
            onAccepted: { authoritativeEvent in
                acceptedEvent?.value = authoritativeEvent
                CmuxEventBus.shared.publishWorkstreamEvent(authoritativeEvent, phase: "received")
                self.v2ApplyIMessageModeSideEffects(for: authoritativeEvent)
                self.agentChatTranscriptService?.noteHookEvent(authoritativeEvent)
                if !waitsForDecision {
                    let acknowledgment = FeedCoordinator.IngestBlockingResult.acknowledged(itemId: nil)
                    CmuxEventBus.shared.publishWorkstreamEvent(
                        authoritativeEvent,
                        phase: "completed",
                        result: FeedSocketEncoding.payload(for: acknowledgment)
                    )
                }
            }
        )
        switch result {
        case .notFound:
            return v2FeedTargetNotFound()
        case .unavailable:
            return v2FeedTargetUnavailable()
        default:
            break
        }
        guard waitsForDecision else {
            return .ok(FeedSocketEncoding.payload(for: result))
        }
        guard let acceptedEvent = acceptedEvent?.value else {
            return .err(
                code: "unavailable",
                message: String(
                    localized: "agent.deliveryTarget.error.unavailable",
                    defaultValue: "Delivery target resolution is unavailable; retry after cmux finishes starting."
                ),
                data: nil
            )
        }
        CmuxEventBus.shared.publishWorkstreamEvent(
            acceptedEvent,
            phase: "completed",
            result: FeedSocketEncoding.payload(for: result)
        )
        var payload = FeedSocketEncoding.payload(for: result)
        v2AppendFeedTarget(from: acceptedEvent, to: &payload)
        return .ok(payload)
    }

    nonisolated private func v2FeedTargetNotFound() -> V2CallResult {
        .err(
            code: "not_found",
            message: String(
                localized: "agent.deliveryTarget.error.notFound",
                defaultValue: "No live delivery target"
            ),
            data: nil
        )
    }

    nonisolated private func v2FeedTargetUnavailable() -> V2CallResult {
        .err(
            code: "unavailable",
            message: String(
                localized: "agent.deliveryTarget.error.unavailable",
                defaultValue: "Delivery target resolution is unavailable; retry after cmux finishes starting."
            ),
            data: nil
        )
    }

    nonisolated private func v2AppendFeedTarget(
        from event: WorkstreamEvent?,
        to payload: inout [String: Any]
    ) {
        guard let event else { return }
        if let workspaceId = event.workspaceId { payload["workspace_id"] = workspaceId }
        if let surfaceId = event.surfaceId { payload["surface_id"] = surfaceId }
    }

    nonisolated func v2FeedPushExclusiveEventShapeMessage() -> String {
        String(
            localized: "feed.push.error.exclusiveEventShape",
            defaultValue: "feed.push accepts either `event` or `events`, not both"
        )
    }

    nonisolated func v2FeedPushRequiresEventMessage() -> String {
        String(
            localized: "feed.push.error.requiresEvent",
            defaultValue: "feed.push requires an `event` object"
        )
    }

    nonisolated func v2FeedPushDecodeFailedMessage(_ error: Error) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "feed.push.error.decodeFailed",
                defaultValue: "feed.push event failed to decode: %@"
            ),
            error.localizedDescription
        )
    }
}

/// Written on the main actor and read after the blocking callback returns.
private final class UnsafeAuthoritativeFeedEventSlot: @unchecked Sendable {
    var value: WorkstreamEvent?
}

private enum FeedBatchIngestion: Sendable {
    case accepted(events: [WorkstreamEvent], itemIds: [UUID])
    case notFound
    case unavailable
}
