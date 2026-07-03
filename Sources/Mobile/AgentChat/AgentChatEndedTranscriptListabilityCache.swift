import Foundation

struct AgentChatEndedTranscriptListabilityCache {
    private struct Entry {
        var isReadable: Bool
        var firstMissingAt: Date?
    }

    private static let missingTranscriptRetryWindow: TimeInterval = 5
    private var entryBySessionID: [String: Entry] = [:]

    mutating func shouldList(
        _ record: AgentChatSessionRecord,
        resolver: AgentChatTranscriptResolver,
        now: Date = Date()
    ) -> Bool {
        guard record.state == .ended else {
            entryBySessionID.removeValue(forKey: record.sessionID)
            return false
        }
        guard let entry = entryBySessionID[record.sessionID] else {
            return refresh(record, resolver: resolver, preservingFirstMissingAt: nil, now: now)
        }
        if entry.isReadable {
            return true
        }
        if let firstMissingAt = entry.firstMissingAt,
           now.timeIntervalSince(firstMissingAt) >= Self.missingTranscriptRetryWindow {
            return false
        }
        return refresh(record, resolver: resolver, preservingFirstMissingAt: entry.firstMissingAt, now: now)
    }

    @discardableResult
    mutating func update(
        _ record: AgentChatSessionRecord,
        previous: AgentChatSessionRecord?,
        resolver: AgentChatTranscriptResolver,
        now: Date = Date()
    ) -> Bool {
        guard record.state == .ended else {
            entryBySessionID.removeValue(forKey: record.sessionID)
            return false
        }
        if let previous,
           previous.state == .ended,
           previous.transcriptPath == record.transcriptPath,
           previous.workingDirectory == record.workingDirectory,
           previous.hookStoreSessionID == record.hookStoreSessionID {
            return shouldList(record, resolver: resolver, now: now)
        }
        return refresh(
            record,
            resolver: resolver,
            preservingFirstMissingAt: nil,
            now: now
        )
    }

    private mutating func refresh(
        _ record: AgentChatSessionRecord,
        resolver: AgentChatTranscriptResolver,
        preservingFirstMissingAt firstMissingAt: Date?,
        now: Date
    ) -> Bool {
        let isReadable = resolver.boundedTranscriptPath(for: record) != nil
        entryBySessionID[record.sessionID] = Entry(
            isReadable: isReadable,
            firstMissingAt: isReadable ? nil : (firstMissingAt ?? now)
        )
        return isReadable
    }

    mutating func remove(sessionID: String) {
        entryBySessionID.removeValue(forKey: sessionID)
    }
}
