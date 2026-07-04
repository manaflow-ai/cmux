import Foundation

/// Metadata and permission request declared by a CMUX extension.
public struct CmuxExtensionManifest: Codable, Equatable, Identifiable, Sendable {
    /// Stable reverse-DNS style identifier for the extension.
    public var id: String

    /// Human-readable extension name shown by CMUX permission and management UI.
    public var displayName: String

    /// Minimum CMUX extension API version required by this extension.
    @_spi(CmuxHostTransport) public var minimumAPIVersion: CmuxExtensionAPIVersion

    /// Sidebar data scopes the extension asks CMUX to include in snapshots.
    public var readScopes: [CmuxExtensionScope]

    /// Host action scopes the extension asks CMUX to allow.
    public var actionScopes: [CmuxExtensionActionScope]

    /// Creates a sidebar extension manifest.
    ///
    /// `minimumAPIVersion` is derived from the requested action scopes: it is the newest
    /// version any requested scope requires (never below the 2.0 baseline). This lets an
    /// author request a newer scope such as `runWorkspaceCommand` without manually setting
    /// the SPI version — the encoded manifest advertises the correct version so older hosts
    /// reject it by version instead of mis-running it with the scope dropped.
    public init(
        id: String,
        displayName: String,
        readScopes: [CmuxExtensionScope] = [],
        actionScopes: [CmuxExtensionActionScope] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.minimumAPIVersion = actionScopes.reduce(.sidebarV2) { max($0, $1.minimumAPIVersion) }
        self.readScopes = readScopes
        self.actionScopes = actionScopes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case minimumAPIVersion
        case readScopes
        case actionScopes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        minimumAPIVersion = try container.decodeIfPresent(CmuxExtensionAPIVersion.self, forKey: .minimumAPIVersion) ?? .sidebarV2
        // Decode scopes tolerantly: an unknown scope from a newer manifest is dropped
        // rather than failing the whole decode, so an older host still recovers
        // `minimumAPIVersion` and rejects the extension by version. Dropping a
        // requested permission is fail-safe — the extension ends up with fewer
        // capabilities, never more.
        readScopes = try container.decodeLossyArray(CmuxExtensionScope.self, forKey: .readScopes)
        actionScopes = try container.decodeLossyArrayIfPresent(CmuxExtensionActionScope.self, forKey: .actionScopes)
    }
}

private extension KeyedDecodingContainer {
    /// Decodes a required array of raw-value-backed scopes, discarding entries whose
    /// raw value is not recognized by this build.
    func decodeLossyArray<Value>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> [Value] where Value: RawRepresentable, Value.RawValue == String {
        let rawValues = try decode([String].self, forKey: key)
        return rawValues.compactMap(type.init(rawValue:))
    }

    /// Decodes an optional array of raw-value-backed scopes, discarding unknown entries
    /// and treating a missing key as an empty list.
    func decodeLossyArrayIfPresent<Value>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> [Value] where Value: RawRepresentable, Value.RawValue == String {
        guard let rawValues = try decodeIfPresent([String].self, forKey: key) else { return [] }
        return rawValues.compactMap(type.init(rawValue:))
    }
}
