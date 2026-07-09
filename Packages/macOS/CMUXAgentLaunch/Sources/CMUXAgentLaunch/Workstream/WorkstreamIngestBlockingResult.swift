import Foundation

/// Outcome of a blocking `feed.push` ingest: whether the item was merely
/// acknowledged (no wait requested), resolved by the user with a
/// ``WorkstreamDecision``, or timed out before the user acted. Each case
/// carries the optional `itemId` of the `WorkstreamItem` the ingest created.
public enum WorkstreamIngestBlockingResult: Sendable {
    case acknowledged(itemId: UUID?)
    case resolved(itemId: UUID?, decision: WorkstreamDecision)
    case timedOut(itemId: UUID?)
}
