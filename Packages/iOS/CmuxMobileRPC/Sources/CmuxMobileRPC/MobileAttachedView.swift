/// One attached view represented in a host's runtime-presence snapshot.
public struct MobileAttachedView: Decodable, Sendable, Equatable {
    /// The stable client identifier supplied by the attached view.
    public let clientID: String
    /// The number of active transports currently identifying as this client.
    public let connectionCount: Int
    /// A user-facing device name, when a newer client supplies one.
    public let displayName: String?
    /// The view kind, such as `ios` or `macos`, when supplied.
    public let kind: String?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case connectionCount = "connection_count"
        case displayName = "display_name"
        case kind
    }
}
