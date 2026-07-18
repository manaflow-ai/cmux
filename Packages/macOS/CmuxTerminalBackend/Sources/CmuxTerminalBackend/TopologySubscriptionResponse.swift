/// The backend's response to a topology resume request.
public enum TopologySubscriptionResponse: Decodable, Equatable, Sendable {
    /// Incremental delivery resumed and includes the subscription metadata.
    case subscribed(TopologySubscription)

    /// Incremental delivery is unsafe and the client must request a new snapshot.
    case resnapshotRequired(BackendResnapshotRequired)

    private enum CodingKeys: String, CodingKey { case status }

    /// Decodes either a successful subscription or a resnapshot instruction.
    ///
    /// - Parameter decoder: The decoder containing the subscription response.
    /// - Throws: ``BackendProtocolError/malformedMessage`` for an unknown status, or a decoding error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "subscribed":
            self = .subscribed(try TopologySubscription(from: decoder))
        case "resnapshot-required":
            self = .resnapshotRequired(try BackendResnapshotRequired(from: decoder))
        default:
            throw BackendProtocolError.malformedMessage
        }
    }
}
