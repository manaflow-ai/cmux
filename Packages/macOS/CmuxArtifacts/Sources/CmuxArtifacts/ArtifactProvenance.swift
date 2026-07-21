import Foundation

/// Describes how cmux learned about an artifact path.
public enum ArtifactProvenance: String, Codable, CaseIterable, Sendable {
    /// An agent created or edited the file.
    case created
    /// The file was attached to an agent conversation.
    case attached
    /// Agent output referred to the file without a structured creation signal.
    case referenced
    /// A user or agent explicitly added the file with `cmux artifact add`.
    case manual
}
