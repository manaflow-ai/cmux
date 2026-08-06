import Foundation

/// Coalesces ended-session transcript checks while filesystem work runs beyond
/// the main actor. Results are keyed by every path input, so a late lookup can
/// never populate the cache for a newer record binding.
@MainActor
final class AgentChatEndedTranscriptListabilityCache {
    typealias ResolvePath = @Sendable () async -> String?
    private typealias RecordKey = [String?]
    private typealias Entry = (
        key: RecordKey,
        isReadable: Bool,
        firstMissingAt: Date?
    )
    private typealias PendingResolution = (
        id: UUID,
        key: RecordKey,
        task: Task<String?, Never>
    )

    private static let missingTranscriptRetryWindow: TimeInterval = 5

    private var entryBySessionID: [String: Entry] = [:]
    private var pendingBySessionID: [String: PendingResolution] = [:]

    func shouldList(
        _ record: AgentChatSessionRecord,
        now: Date = Date(),
        resolvePath: @escaping ResolvePath
    ) async -> Bool {
        guard record.state == .ended else {
            remove(sessionID: record.sessionID)
            return false
        }
        let key = recordKey(for: record)
        if let entry = entryBySessionID[record.sessionID], entry.key == key {
            if entry.isReadable {
                return true
            }
            if let firstMissingAt = entry.firstMissingAt,
               now.timeIntervalSince(firstMissingAt) < Self.missingTranscriptRetryWindow {
                return false
            }
        }
        return await refresh(record, key: key, now: now, resolvePath: resolvePath)
    }

    func update(
        _ record: AgentChatSessionRecord,
        previous: AgentChatSessionRecord?,
        now: Date = Date(),
        resolvePath: @escaping ResolvePath
    ) async -> Bool {
        guard record.state == .ended else {
            remove(sessionID: record.sessionID)
            return false
        }
        if let previous,
           previous.state == .ended,
           previous.transcriptPath == record.transcriptPath,
           previous.workingDirectory == record.workingDirectory,
           previous.hookStoreSessionID == record.hookStoreSessionID {
            return await shouldList(record, now: now, resolvePath: resolvePath)
        }
        return await refresh(
            record,
            key: recordKey(for: record),
            now: now,
            resolvePath: resolvePath
        )
    }

    private func refresh(
        _ record: AgentChatSessionRecord,
        key: RecordKey,
        now: Date,
        resolvePath: @escaping ResolvePath
    ) async -> Bool {
        if let pending = pendingBySessionID[record.sessionID], pending.key == key {
            return await pending.task.value != nil
        }

        pendingBySessionID.removeValue(forKey: record.sessionID)?.task.cancel()
        let id = UUID()
        let task = Task {
            await resolvePath()
        }
        pendingBySessionID[record.sessionID] = (
            id: id,
            key: key,
            task: task
        )

        let isReadable = await task.value != nil
        guard let pending = pendingBySessionID[record.sessionID],
              pending.id == id,
              pending.key == key else {
            return isReadable
        }
        pendingBySessionID.removeValue(forKey: record.sessionID)
        guard !task.isCancelled else { return false }
        entryBySessionID[record.sessionID] = (
            key: key,
            isReadable: isReadable,
            firstMissingAt: isReadable ? nil : now
        )
        return isReadable
    }

    func remove(sessionID: String) {
        entryBySessionID.removeValue(forKey: sessionID)
        pendingBySessionID.removeValue(forKey: sessionID)?.task.cancel()
    }

    private func recordKey(for record: AgentChatSessionRecord) -> RecordKey {
        [
            record.transcriptPath,
            record.workingDirectory,
            record.hookStoreSessionID,
        ]
    }
}
