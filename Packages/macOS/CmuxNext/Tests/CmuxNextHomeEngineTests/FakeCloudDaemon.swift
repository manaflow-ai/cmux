import CmuxNextDaemon
import Foundation

/// A daemon's cloud proxy without a daemon: it answers the reads a Cloud
/// source makes when it connects (an empty inbox, live subscriptions) and
/// records every command the tests look at.
actor FakeCloudDaemon: CloudConversationCommands {
    /// One `cloud-inbox-op` as the daemon received it.
    struct InboxOp: Equatable {
        var conversation: String
        var idempotencyKey: String
        var op: ConversationInboxOpRequest.Op
    }

    private(set) var inboxOps: [InboxOp] = []

    func inboxList(limit: Int) async throws -> CloudInboxList { CloudInboxList(entries: []) }

    func snapshot(_ conversation: String, tail: Int) async throws -> CloudConversationSnapshot {
        throw DaemonError.notConnected
    }

    func history(_ conversation: String, before seq: UInt64, limit: Int) async throws -> CloudConversationHistory {
        CloudConversationHistory(messages: [], hasMore: false)
    }

    func op(_ request: CloudConversationOpRequest) async throws -> CloudConversationOpResult {
        throw DaemonError.notConnected
    }

    func subscribeInbox() async throws -> CloudSubscription { CloudSubscription(state: "live") }

    func subscribe(_ conversation: String) async throws -> CloudSubscription {
        CloudSubscription(conversation: conversation, state: "live")
    }

    func unsubscribe(_ conversation: String) async throws {}

    func inboxOp(_ conversation: String, idempotencyKey: String, op: ConversationInboxOpRequest.Op) async throws {
        inboxOps.append(InboxOp(conversation: conversation, idempotencyKey: idempotencyKey, op: op))
    }
}
