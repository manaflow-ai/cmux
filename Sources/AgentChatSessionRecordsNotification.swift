import Foundation

extension Notification.Name {
    /// Invalidation-only signal. Consumers re-read AgentChatTranscriptService;
    /// the notification carries no duplicate session state.
    static let agentChatSessionRecordsDidChange = Notification.Name("agentChatSessionRecordsDidChange")
    static let agentChatSessionHistoryDidChange = Notification.Name("agentChatSessionHistoryDidChange")
}
