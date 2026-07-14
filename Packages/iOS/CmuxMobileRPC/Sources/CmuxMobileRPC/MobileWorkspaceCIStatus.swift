/// The aggregate CI state associated with a remote workspace's pull request.
public enum MobileWorkspaceCIStatus: String, Decodable, Sendable, Equatable {
    /// All reported checks completed successfully.
    case success
    /// At least one reported check failed.
    case failure
    /// At least one reported check is still running or queued.
    case pending
    /// The host has no authoritative CI result or reported a newer value.
    case unknown

    /// Decodes a CI state while preserving forward compatibility with newer hosts.
    /// - Parameter decoder: The decoder for the CI-state string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}
