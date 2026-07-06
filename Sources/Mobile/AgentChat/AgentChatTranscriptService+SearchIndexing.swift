import Foundation

extension AgentChatTranscriptService {
    func enableSearchIndexing(indexer: GlobalSearchTranscriptIndexer) {
        searchTranscriptIndexer = indexer
        searchIndexingSink = { sessionID, batch in
            Task {
                await indexer.ingest(sessionID: sessionID, batch: batch)
            }
        }
        for record in registry.sessions(workspaceID: nil) {
            activateSearchIndexingIfNeeded(for: record)
        }
    }

    func activateSearchIndexingIfNeeded(for record: AgentChatSessionRecord) {
        guard record.state != .ended,
              record.workspaceID != nil,
              record.surfaceID != nil,
              let indexer = searchTranscriptIndexer else {
            return
        }
        Task {
            await indexer.updateSessionBinding(
                sessionID: record.sessionID,
                workspaceID: record.workspaceID,
                panelID: record.surfaceID,
                title: record.title
            )
        }
        ensureSearchIndexingTailer(for: record)
    }
}
