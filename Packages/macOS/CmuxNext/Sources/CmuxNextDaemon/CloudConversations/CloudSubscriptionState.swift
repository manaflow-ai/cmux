import Foundation

/// `cloud-subscription-state` of the inbox or one conversation socket.

/// `cloud-subscription-state` of the inbox or one conversation socket.
public struct CloudSubscriptionState: Decodable, Sendable, Hashable {
    /// `inbox` or `conversation`.
    public var scope: String
    public var conversation: String?
    /// `connecting`, `live`, `disconnected` or `closed`.
    public var state: String
    /// `signed_out`, `unauthenticated`, `unavailable` (disconnected) or `forbidden` (closed).
    public var reason: String?
    /// The cloud account (the lease's `sub`) the socket runs as; absent without one.
    public var account: String?

    public init(scope: String, conversation: String? = nil, state: String, reason: String? = nil, account: String? = nil) {
        self.scope = scope
        self.conversation = conversation
        self.state = state
        self.reason = reason
        self.account = account
    }

    public var isLive: Bool { state == "live" }
}
