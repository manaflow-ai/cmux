/// How an artifact path entered an agent session's transcript-derived gallery.
public enum ChatArtifactProvenance: String, Sendable, Equatable, Codable, CaseIterable {
    /// The agent created or edited the path.
    case created
    /// The user attached the path to the conversation.
    case attached
    /// A tool read or otherwise mentioned the path.
    case referenced

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = (try? container.decode(String.self)).flatMap(Self.init(rawValue:)) ?? .referenced
    }
}
