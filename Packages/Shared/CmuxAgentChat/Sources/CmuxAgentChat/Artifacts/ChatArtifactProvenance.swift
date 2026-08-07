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

    /// Returns the provenance that grants stronger capture authority.
    func preferred(over candidate: ChatArtifactProvenance) -> ChatArtifactProvenance {
        capturePrecedence <= candidate.capturePrecedence ? self : candidate
    }

    /// Converts capture-authorizing provenance into its sequence-bound grant.
    func captureAuthorization(sequence: Int) -> ChatArtifactCaptureAuthorization? {
        switch self {
        case .created: .created(sequence: sequence)
        case .attached: .attached(sequence: sequence)
        case .referenced: nil
        }
    }

    private var capturePrecedence: Int {
        switch self {
        case .created: 0
        case .attached: 1
        case .referenced: 2
        }
    }
}
