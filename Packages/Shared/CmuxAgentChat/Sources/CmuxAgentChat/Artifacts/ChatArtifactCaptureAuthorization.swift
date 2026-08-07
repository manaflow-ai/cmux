/// A transcript occurrence that authorizes copying an artifact into project storage.
public enum ChatArtifactCaptureAuthorization: Sendable, Equatable, Codable {
    /// A successful agent mutation at the associated transcript sequence.
    case created(sequence: Int)
    /// A user attachment at the associated transcript sequence.
    case attached(sequence: Int)

    /// Transcript sequence that granted the authorization.
    public var sequence: Int {
        switch self {
        case .created(let sequence), .attached(let sequence): sequence
        }
    }

    /// Capture provenance represented by this authorization.
    public var provenance: ChatArtifactProvenance {
        switch self {
        case .created: .created
        case .attached: .attached
        }
    }

    /// Returns the newer grant, breaking sequence ties by provenance authority.
    func latest(with candidate: ChatArtifactCaptureAuthorization) -> ChatArtifactCaptureAuthorization {
        if sequence != candidate.sequence {
            return sequence > candidate.sequence ? self : candidate
        }
        return provenance.preferred(over: candidate.provenance) == provenance ? self : candidate
    }
}
