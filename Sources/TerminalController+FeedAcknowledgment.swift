import CMUXAgentLaunch
import Foundation

extension TerminalController {
    /// Reconciles, publishes, and inserts acknowledged Feed events atomically.
    nonisolated func v2IngestAcknowledgedFeedEvents(
        _ events: [WorkstreamEvent]
    ) -> V2CallResult {
        v2MainSync {
            guard let authoritativeEvents = FeedCoordinator.shared.eventsRehomedToLiveSurface(events)
            else {
                return .err(
                    code: "not_found",
                    message: String(
                        localized: "agent.deliveryTarget.error.notFound",
                        defaultValue: "No live delivery target"
                    ),
                    data: nil
                )
            }

            var itemIds: [String] = []
            itemIds.reserveCapacity(authoritativeEvents.count)
            for event in authoritativeEvents {
                CmuxEventBus.shared.publishWorkstreamEvent(event, phase: "received")
                v2ApplyIMessageModeSideEffects(for: event)
                agentChatTranscriptService?.noteHookEvent(event)

                let itemId = FeedCoordinator.shared.ingestRevalidatedOnMainActor(event)
                let result = FeedCoordinator.IngestBlockingResult.acknowledged(itemId: itemId)
                CmuxEventBus.shared.publishWorkstreamEvent(
                    event,
                    phase: "completed",
                    result: FeedSocketEncoding.payload(for: result)
                )
                if let itemId {
                    itemIds.append(itemId.uuidString)
                }
            }

            guard itemIds.count == authoritativeEvents.count else {
                return .err(
                    code: "unavailable",
                    message: String(
                        localized: "agent.deliveryTarget.error.unavailable",
                        defaultValue: "Delivery target resolution is unavailable; retry after cmux finishes starting."
                    ),
                    data: nil
                )
            }
            if itemIds.count == 1, let itemId = itemIds.first {
                return .ok([
                    "status": "acknowledged",
                    "item_id": itemId,
                ])
            }
            return .ok([
                "status": "acknowledged",
                "item_ids": itemIds,
            ])
        }
    }

    /// Publishes and inserts one Feed event from one authoritative live-target snapshot.
    nonisolated func v2IngestFeedEvent(
        _ event: WorkstreamEvent,
        waitTimeout: TimeInterval
    ) -> V2CallResult {
        let acceptedEvent = UnsafeAuthoritativeFeedEventSlot()
        let waitsForDecision = waitTimeout > 0 && event.requestId != nil
        let result = FeedCoordinator.shared.ingestBlocking(
            event: event,
            waitTimeout: waitTimeout,
            onAccepted: { authoritativeEvent in
                acceptedEvent.value = authoritativeEvent
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
        if case .unavailable = result {
            return .err(
                code: "not_found",
                message: String(
                    localized: "agent.deliveryTarget.error.notFound",
                    defaultValue: "No live delivery target"
                ),
                data: nil
            )
        }
        guard waitsForDecision else {
            return .ok(FeedSocketEncoding.payload(for: result))
        }
        guard let acceptedEvent = acceptedEvent.value else {
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
        return .ok(FeedSocketEncoding.payload(for: result))
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
