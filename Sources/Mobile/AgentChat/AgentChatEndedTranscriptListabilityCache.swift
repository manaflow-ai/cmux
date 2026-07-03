import Foundation

struct AgentChatEndedTranscriptListabilityCache {
    private var readableBySessionID: [String: Bool] = [:]

    func shouldList(_ record: AgentChatSessionRecord) -> Bool {
        readableBySessionID[record.sessionID] == true
    }

    mutating func update(
        _ record: AgentChatSessionRecord,
        previous: AgentChatSessionRecord?,
        resolver: AgentChatTranscriptResolver
    ) {
        guard record.state == .ended else {
            readableBySessionID.removeValue(forKey: record.sessionID)
            return
        }
        if let previous,
           previous.state == .ended,
           previous.transcriptPath == record.transcriptPath,
           previous.workingDirectory == record.workingDirectory,
           previous.hookStoreSessionID == record.hookStoreSessionID,
           readableBySessionID[record.sessionID] != nil {
            return
        }
        readableBySessionID[record.sessionID] = resolver.boundedTranscriptPath(for: record) != nil
    }

    mutating func remove(sessionID: String) {
        readableBySessionID.removeValue(forKey: sessionID)
    }
}
