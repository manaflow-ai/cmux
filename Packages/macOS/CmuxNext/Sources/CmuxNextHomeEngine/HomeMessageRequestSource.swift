public import CmuxHomeCore
public import CmuxNextHome

/// Where Home's message requests come from and go to (DESIGN 2.3). `CloudHomeSource` is the
/// real one, over the daemon's `cloud-requests-list` and `cloud-conversation-op`; tests pass a fake.
public protocol HomeMessageRequestSource: Sendable {
    /// The account's open requests, newest first; none without a leased cloud connection.
    func messageRequests() async throws -> [HomeMessageRequest]
    /// Sends one answer; throws when the owner refused it or could not be reached.
    func answer(_ conversation: ConversationID, _ answer: HomeRequestAnswer) async throws
}
