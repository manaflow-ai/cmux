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
}
