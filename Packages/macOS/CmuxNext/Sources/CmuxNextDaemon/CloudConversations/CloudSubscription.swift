import Foundation


/// `cloud-*-subscribe` data: `connecting` with a lease, otherwise `disconnected`.
public struct CloudSubscription: Decodable, Sendable, Equatable {
    public var conversation: String?
    /// The shared socket's true state now (a `cloud-subscription-state` event follows).
    public var state: String
    public var reason: String?
    /// The cloud account (the lease's `sub`) the socket runs as; absent without one.
    public var account: String?

    public init(conversation: String? = nil, state: String, reason: String? = nil, account: String? = nil) {
        self.conversation = conversation
        self.state = state
        self.reason = reason
        self.account = account
    }

    enum CodingKeys: String, CodingKey { case conversation, state, reason, account }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "disconnected"
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        account = try c.decodeIfPresent(String.self, forKey: .account)
    }
}
