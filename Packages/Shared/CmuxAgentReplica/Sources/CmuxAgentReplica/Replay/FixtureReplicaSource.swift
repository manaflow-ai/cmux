import Foundation

/// Feeds scripted replay records into replica stores.
public struct FixtureReplicaSource: Sendable {
    /// Scripted replay records.
    public let records: [ReplicaReplayRecord]

    /// Creates a fixture source.
    /// - Parameter records: Scripted replay records.
    public init(records: [ReplicaReplayRecord]) {
        self.records = records
    }

    /// Applies all records to existing stores.
    /// - Parameters:
    ///   - directory: The session directory store.
    ///   - conversations: Existing conversation stores keyed by session identifier.
    @MainActor public func feed(
        directory: SessionDirectoryReplica,
        conversations: [AgentSessionID: ConversationReplica]
    ) {
        for record in records {
            directory.apply(record.delta, origin: record.origin)
            for conversation in conversations.values {
                conversation.apply(record.delta, origin: record.origin)
            }
        }
    }
}
