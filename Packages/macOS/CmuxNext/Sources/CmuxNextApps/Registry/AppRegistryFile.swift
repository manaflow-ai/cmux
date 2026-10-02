public import Foundation

/// The prototype install record (`<apps dir>/registry.json`). TEMPORARY
/// stand-in for installs in UserDO/TeamDO (spec section 11): the cloud
/// install record will own installs and grants and this file goes away.
/// Absent entries mean the default: bundled first-party samples and
/// `local/` development apps are installed and enabled.
public nonisolated struct AppRegistryFile: Sendable, Hashable, Codable {
    public struct Entry: Sendable, Hashable, Codable {
        public var installed: Bool
        public var enabled: Bool
        public var changedAt: Date
        /// Requested scopes the user revoked.
        public var revokedScopes: [String]
        /// Optional scopes the user granted.
        public var grantedOptionalScopes: [String]
        /// The "Run sandboxed" switch; nil = the tier's default.
        public var sandboxed: Bool?

        public init(installed: Bool, enabled: Bool, changedAt: Date = Date(), revokedScopes: [String] = [],
                    grantedOptionalScopes: [String] = [], sandboxed: Bool? = nil) {
            self.installed = installed
            self.enabled = enabled
            self.changedAt = changedAt
            self.revokedScopes = revokedScopes
            self.grantedOptionalScopes = grantedOptionalScopes
            self.sandboxed = sandboxed
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            installed = try c.decode(Bool.self, forKey: .installed)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            changedAt = try c.decodeIfPresent(Date.self, forKey: .changedAt) ?? .distantPast
            revokedScopes = try c.decodeIfPresent([String].self, forKey: .revokedScopes) ?? []
            grantedOptionalScopes = try c.decodeIfPresent([String].self, forKey: .grantedOptionalScopes) ?? []
            sandboxed = try c.decodeIfPresent(Bool.self, forKey: .sandboxed)
        }
    }

    public var version = 1
    public var apps: [String: Entry] = [:]

    public init(apps: [String: Entry] = [:]) {
        self.apps = apps
    }

    public func entry(_ id: String) -> Entry { apps[id] ?? Entry(installed: true, enabled: true, changedAt: .distantPast) }

    /// `~/Library/Application Support/cmux/<tag or "default">/apps`, the
    /// per-tag convention of the other app-support files.
    public static func appsDirectory(tag: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/cmux", directoryHint: .isDirectory)
            .appending(path: tag ?? "default", directoryHint: .isDirectory)
            .appending(path: "apps", directoryHint: .isDirectory)
    }

    static func load(from url: URL) -> AppRegistryFile {
        guard let data = try? Data(contentsOf: url) else { return AppRegistryFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AppRegistryFile.self, from: data)) ?? AppRegistryFile()
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
