/// The lifecycle of a pull request associated with a remote workspace.
public enum MobileWorkspacePullRequestLifecycle: String, Decodable, Sendable, Equatable {
    /// The pull request is open.
    case open
    /// The pull request was merged.
    case merged
    /// The pull request was closed without merging.
    case closed
    /// The host reported a lifecycle value this client does not recognize.
    case unknown

    /// Decodes a lifecycle while preserving forward compatibility with newer hosts.
    /// - Parameter decoder: The decoder for the lifecycle string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}
