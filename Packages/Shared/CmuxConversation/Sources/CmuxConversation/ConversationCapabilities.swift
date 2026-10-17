public import Foundation

/// Native capabilities advertised by a provider adapter.
public struct ConversationCapabilities: Codable, Hashable, Sendable {
    /// Provider protocol name and version, such as `codex-app-server/1`.
    public var protocolVersion: String
    /// Stable capability identifiers supported by this connection.
    public var features: Set<String>
    /// Provider model identifiers offered by this connection.
    public var models: [String]
    /// Valid effort/intelligence values offered by this connection.
    public var efforts: [String]
    /// Valid speed values offered by this connection.
    public var speeds: [String]
    /// Whether the adapter can resume a provider session after a process restart.
    public var supportsResume: Bool
    /// Whether this adapter can expose raw provider payloads in its journal.
    public var preservesRawPayloads: Bool

    /// Creates a capability declaration.
    /// - Parameters:
    ///   - protocolVersion: Provider protocol version.
    ///   - features: Feature identifiers.
    ///   - supportsResume: Whether native resume is available.
    ///   - preservesRawPayloads: Whether raw payloads are retained.
    public init(protocolVersion: String, features: Set<String> = [], models: [String] = [], efforts: [String] = [], speeds: [String] = [], supportsResume: Bool, preservesRawPayloads: Bool = true) {
        self.protocolVersion = protocolVersion
        self.features = features
        self.models = models
        self.efforts = efforts
        self.speeds = speeds
        self.supportsResume = supportsResume
        self.preservesRawPayloads = preservesRawPayloads
    }
}
