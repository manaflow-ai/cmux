internal import Foundation

/// The release manifest describing downloadable cmuxd-remote daemon binaries
/// bundled with the app (read side; decoding only).
///
/// Wire shape: decoded from the JSON manifest embedded in the app's Info
/// dictionary; do not rename stored properties.
public struct WorkspaceRemoteDaemonManifest: Decodable, Equatable, Sendable {
    /// One platform-specific daemon binary release entry.
    public struct Entry: Decodable, Equatable, Sendable {
        /// Target GOOS (e.g. `linux`, `darwin`).
        public let goOS: String
        /// Target GOARCH (e.g. `amd64`, `arm64`).
        public let goArch: String
        /// Release asset filename.
        public let assetName: String
        /// Direct download URL for the asset.
        public let downloadURL: String
        /// Hex SHA-256 of the asset.
        public let sha256: String
    }

    /// Manifest schema version.
    public let schemaVersion: Int
    /// cmux app version the manifest was generated for.
    public let appVersion: String
    /// Git release tag of the daemon build.
    public let releaseTag: String
    /// Release page URL.
    public let releaseURL: String
    /// Checksums asset filename.
    public let checksumsAssetName: String
    /// Checksums asset URL.
    public let checksumsURL: String
    /// All platform entries in the release.
    public let entries: [Entry]

    /// Returns the entry matching the platform pair, when present.
    public func entry(goOS: String, goArch: String) -> Entry? {
        entries.first { $0.goOS == goOS && $0.goArch == goArch }
    }
}

extension WorkspaceRemoteDaemonManifest {
    /// Info-dictionary key under which release builds embed the manifest
    /// JSON (`CMUXRemoteDaemonManifestJSON`); wire-pinned.
    public static let infoDictionaryKey = "CMUXRemoteDaemonManifestJSON"

    /// Decodes the manifest embedded in an app's Info dictionary, or `nil`
    /// when the key is absent, blank, or undecodable (dev builds embed no
    /// manifest).
    public init?(infoDictionary: [String: Any]?) {
        guard let rawManifest = infoDictionary?[Self.infoDictionaryKey] as? String else { return nil }
        let trimmed = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let manifest = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = manifest
    }
}
