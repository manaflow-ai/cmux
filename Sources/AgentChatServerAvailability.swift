import Foundation

struct AgentChatServerAvailability: Sendable {
    var isReachable: Bool
    /// nil means the owned launch failed and nothing safe exists to open;
    /// the action must fail instead of falling back to the legacy URL.
    var browserURL: URL?
}
