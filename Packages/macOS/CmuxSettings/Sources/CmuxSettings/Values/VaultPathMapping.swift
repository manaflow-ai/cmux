import Foundation

/// A bidirectional path-prefix equivalence used by Vault session discovery.
///
/// Claude transcripts captured on a mounted remote filesystem often record a
/// remote cwd such as `/workspace/project`, while cmux sees the same files under
/// a local path such as `/Users/alice/project`. Vault uses this value to compare
/// those paths as the same folder.
public struct VaultPathMapping: Sendable, Hashable, Codable, SettingCodable {
    /// Prefix as recorded inside the remote agent transcript.
    public let remotePrefix: String

    /// Prefix for the same directory tree on the local Mac filesystem.
    public let localPrefix: String

    /// Creates a path mapping from a remote prefix to its local equivalent.
    ///
    /// - Parameters:
    ///   - remotePrefix: The prefix recorded in agent transcripts.
    ///   - localPrefix: The equivalent local prefix visible to cmux.
    public init(remotePrefix: String, localPrefix: String) {
        self.remotePrefix = remotePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localPrefix = localPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case remotePrefix
        case localPrefix
        case remote
        case local
    }

    /// Decodes a mapping from `remotePrefix`/`localPrefix`.
    ///
    /// The shorter aliases `remote` and `local` are accepted for hand-written
    /// `cmux.json` files.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let remote = try container.decodeIfPresent(String.self, forKey: .remotePrefix)
            ?? container.decodeIfPresent(String.self, forKey: .remote)
            ?? ""
        let local = try container.decodeIfPresent(String.self, forKey: .localPrefix)
            ?? container.decodeIfPresent(String.self, forKey: .local)
            ?? ""
        self.init(remotePrefix: remote, localPrefix: local)
        guard isUsable else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Vault path mappings require non-empty remotePrefix and localPrefix"
                )
            )
        }
    }

    /// Encodes the canonical `remotePrefix`/`localPrefix` object shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remotePrefix, forKey: .remotePrefix)
        try container.encode(localPrefix, forKey: .localPrefix)
    }

    /// Decodes a mapping from a loose property-list object.
    public static func decodeFromUserDefaults(_ raw: Any?) -> VaultPathMapping? {
        decodeFromLooseObject(raw)
    }

    /// Encodes a property-list-compatible object for storage.
    public func encodeForUserDefaults() -> Any {
        encodeForJSON()
    }

    /// Decodes a mapping from a `JSONSerialization` object.
    public static func decodeFromJSON(_ raw: Any?) -> VaultPathMapping? {
        decodeFromLooseObject(raw)
    }

    /// Encodes a `JSONSerialization`-compatible object for `cmux.json`.
    public func encodeForJSON() -> Any {
        [
            "remotePrefix": remotePrefix,
            "localPrefix": localPrefix,
        ]
    }

    private var isUsable: Bool {
        !remotePrefix.isEmpty && !localPrefix.isEmpty
    }

    private static func decodeFromLooseObject(_ raw: Any?) -> VaultPathMapping? {
        guard let object = raw as? [String: Any] else { return nil }
        let remote = object["remotePrefix"] as? String
            ?? object["remote"] as? String
            ?? ""
        let local = object["localPrefix"] as? String
            ?? object["local"] as? String
            ?? ""
        let mapping = VaultPathMapping(remotePrefix: remote, localPrefix: local)
        return mapping.isUsable ? mapping : nil
    }
}
