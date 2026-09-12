import Foundation

extension WorkstreamStore {
    /// Ingests a feed event, preserving the state of an identical actionable retry.
    /// - Parameter event: The incoming event.
    public func ingest(_ event: WorkstreamEvent) {
        _ = ingestReturningItem(event)
    }

    /// Returns the inserted or already-existing actionable item.
    /// - Parameter event: The incoming event; request IDs identify immutable input.
    /// - Returns: The current item, or `nil` when a reused request ID changes its scope or payload.
    @discardableResult
    public func ingestReturningItem(_ event: WorkstreamEvent) -> WorkstreamItem? {
        let item = makeItem(from: event)
        if let requestID = event.requestId, !requestID.isEmpty,
           let existing = items.last(where: { $0.payload.requestID == requestID }) {
            guard existing.workstreamId == item.workstreamId, existing.source == item.source,
                  existing.sourceID == item.sourceID, existing.kind == item.kind,
                  existing.payload == item.payload else { return nil }
            return existing
        }
        ingestPrepared(item)
        return item
    }
}
