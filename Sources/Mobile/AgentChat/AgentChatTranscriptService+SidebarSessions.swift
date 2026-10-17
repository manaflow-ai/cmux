import CmuxAgentChat
import Foundation

/// The service's contribution to the sidebar session rows: pane lookups, the
/// last-typed ordering, and off-main transcript tail reads that fill Claude's
/// own title and the last prompt.
extension AgentChatTranscriptService {
    /// The one non-ended record bound to a pane (`surfaceID` is the panel UUID string).
    func liveSessionRecord(surfaceID: String) -> AgentChatSessionRecord? {
        registry.liveSession(surfaceID: surfaceID)
    }

    /// Live, surface-bound records ordered by their last hook prompt, newest first.
    func lastTypedLiveSessions() -> [AgentChatSessionRecord] {
        registry.lastTypedLiveSessions()
    }

    /// Reads the transcript tail for a Claude session off the main actor and
    /// applies the newest `ai-title` / `last-prompt` to the record. Skipped for
    /// other agents, ended records, records without a transcript path, and
    /// while a read for the same session is already in flight.
    func scheduleTranscriptTailRead(for record: AgentChatSessionRecord) {
        guard record.agentKind == .claude,
              record.state != .ended,
              let path = record.transcriptPath,
              !path.isEmpty else { return }
        let sessionID = record.sessionID
        guard !transcriptTailReadsInFlight.contains(sessionID) else { return }
        transcriptTailReadsInFlight.insert(sessionID)
        let reader = transcriptTailReader
        Task.detached(priority: .utility) { [weak self] in
            let tail = reader.read(path: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.transcriptTailReadsInFlight.remove(sessionID)
                if let tail {
                    self.registry.applyTranscriptTail(sessionID: sessionID, tail: tail)
                }
            }
        }
    }
}
