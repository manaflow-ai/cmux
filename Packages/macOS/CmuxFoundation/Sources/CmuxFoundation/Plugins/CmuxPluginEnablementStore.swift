public import Foundation

/// Persists which extension plugins are enabled.
///
/// Enabling records the SHA-256 of the manifest the user reviewed. When an
/// update changes the manifest (and so the commands it runs), the plugin
/// stops running until it is enabled again.
public struct CmuxPluginEnablementStore: Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var fingerprint: String

        public init(fingerprint: String) {
            self.fingerprint = fingerprint
        }
    }

    private struct FileContents: Codable {
        var version = 1
        var enabled: [String: Record] = [:]
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Enabled records keyed by plugin name. A missing or unreadable file
    /// means nothing is enabled, which is the safe default.
    public func load() -> [String: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= 1024 * 1024,
              let contents = try? JSONDecoder().decode(FileContents.self, from: data),
              contents.version == 1 else {
            return [:]
        }
        return contents.enabled
    }

    public func enable(_ name: String, fingerprint: String) throws {
        var records = load()
        records[name] = Record(fingerprint: fingerprint)
        try save(records)
    }

    public func disable(_ name: String) throws {
        var records = load()
        guard records.removeValue(forKey: name) != nil else { return }
        try save(records)
    }

    private func save(_ records: [String: Record]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileContents(enabled: records))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
