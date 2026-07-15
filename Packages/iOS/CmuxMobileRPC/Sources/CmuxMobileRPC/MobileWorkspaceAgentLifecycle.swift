/// The lifecycle state of an agent attached to a remote workspace.
public enum MobileWorkspaceAgentLifecycle: String, Decodable, Sendable, Equatable {
    /// The agent is actively working.
    case running
    /// The agent is alive but waiting for more work.
    case idle
    /// The agent is blocked on a decision or other user input.
    case needsInput = "needs_input"
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
