/// Parameters for `mobile.attach_ticket.create` requests.
public struct MobileAttachTicketCreateParams: Encodable, Sendable {
    /// Requested ticket lifetime in seconds.
    public var ttlSeconds: Int
    /// The requested ticket scope (e.g. `"mac"` for a Mac-wide ticket).
    public var scope: String

    /// Create attach-ticket-create parameters.
    /// - Parameters:
    ///   - ttlSeconds: Requested ticket lifetime in seconds.
    ///   - scope: The requested ticket scope (e.g. `"mac"`).
    public init(ttlSeconds: Int, scope: String) {
        self.ttlSeconds = ttlSeconds
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
        case scope
    }
}
