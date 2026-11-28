/// Placeholder for a wire payload type this client does not understand.
///
/// Keeps older clients fail-open when the producer starts emitting new
/// ``ChatMessageKind`` cases: the message stays in the transcript and
/// renders as a generic row instead of being dropped.
public struct ChatUnsupportedPayload: Sendable, Equatable, Codable {
    /// The unrecognized wire `type` discriminator.
    public let rawType: String

    /// Creates an unsupported-payload placeholder.
    ///
    /// - Parameter rawType: The unrecognized wire `type` discriminator.
    public init(rawType: String) {
        self.rawType = rawType
    }

    private enum CodingKeys: String, CodingKey {
        case rawType = "raw_type"
    }
}
