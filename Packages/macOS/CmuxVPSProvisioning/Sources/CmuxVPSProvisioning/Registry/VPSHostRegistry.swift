internal import CmuxSettings
public import Foundation

/// Persistent registry of provisioned VPS hosts, one JSON file under the
/// shared cmux state directory (`~/.local/state/cmux/vps/hosts.json`).
///
/// The CLI is the only writer (`cmux vps add/remove/upgrade`); `cmux ssh`
/// reads it to pin workspaces on registered hosts to the shared supervised
/// daemon slot. An actor serializes concurrent access within one process;
/// writes are atomic replaces so concurrent readers never see a torn file.
public actor VPSHostRegistry {
    private let fileURL: URL

    /// Creates a registry rooted at the standard state directory.
    ///
    /// - Parameter homeDirectory: The user's home directory; composition
    ///   roots pass `FileManager.default.homeDirectoryForCurrentUser` so the
    ///   app and CLI agree on the path independently of `$HOME` overrides.
    public init(homeDirectory: URL) {
        self.fileURL = Self.registryFileURL(homeDirectory: homeDirectory)
    }

    /// The registry file path for `homeDirectory` (exposed for tests and
    /// diagnostics output).
    public static func registryFileURL(homeDirectory: URL) -> URL {
        CmuxStateDirectory.url(homeDirectory: homeDirectory)
            .appendingPathComponent("vps", isDirectory: true)
            .appendingPathComponent("hosts.json", isDirectory: false)
    }

    /// All registered hosts, sorted by registry key.
    ///
    /// - Throws: ``VPSProvisioningError/registryFailure(detail:)`` when the
    ///   file exists but cannot be read or decoded.
    public func allHosts() throws -> [VPSRegisteredHost] {
        try load().values.sorted { $0.host.registryKey < $1.host.registryKey }
    }

    /// The entry for `host`, or `nil` when unregistered.
    public func entry(for host: VPSHostDescriptor) throws -> VPSRegisteredHost? {
        try load()[host.storageKey]
    }

    /// The entry matching a raw destination string plus optional port, or
    /// `nil`. Used by `cmux ssh` to decide slot pinning.
    public func entry(destination: String, port: Int?) throws -> VPSRegisteredHost? {
        try entry(for: VPSHostDescriptor(destination: destination, port: port))
    }

    /// Resolves a CLI-supplied destination to a registered entry: the exact
    /// destination+port key first; when no port was supplied, the unique
    /// entry with that destination — so `cmux vps upgrade user@host` finds a
    /// host registered with `--port 2222`. Ambiguous bare destinations (same
    /// destination on several ports) resolve to `nil` so the caller fails
    /// with "not registered" instead of guessing.
    public func resolve(destination: String, port: Int?) throws -> VPSRegisteredHost? {
        let hosts = try load()
        if let exact = hosts[VPSHostDescriptor(destination: destination, port: port).storageKey] {
            return exact
        }
        guard port == nil else { return nil }
        let matches = hosts.values.filter { $0.host.destination == destination }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    /// Inserts or replaces the entry for its host key.
    public func upsert(_ entry: VPSRegisteredHost) throws {
        var hosts = try load()
        hosts[entry.host.storageKey] = entry
        try save(hosts)
    }

    /// Removes the entry for `host`.
    ///
    /// - Returns: The removed entry, or `nil` when it was not registered.
    @discardableResult
    public func remove(_ host: VPSHostDescriptor) throws -> VPSRegisteredHost? {
        var hosts = try load()
        let removed = hosts.removeValue(forKey: host.storageKey)
        if removed != nil {
            try save(hosts)
        }
        return removed
    }

    private struct RegistryFile: Codable {
        var version: Int
        var hosts: [VPSRegisteredHost]
    }

    private func load() throws -> [String: VPSRegisteredHost] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(RegistryFile.self, from: data)
            return Dictionary(
                file.hosts.map { ($0.host.storageKey, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
        } catch {
            throw VPSProvisioningError.registryFailure(
                detail: "cannot read \(fileURL.path): \(error.localizedDescription)"
            )
        }
    }

    private func save(_ hosts: [String: VPSRegisteredHost]) throws {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = RegistryFile(
                version: 1,
                hosts: hosts.values.sorted { $0.host.registryKey < $1.host.registryKey }
            )
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw VPSProvisioningError.registryFailure(
                detail: "cannot write \(fileURL.path): \(error.localizedDescription)"
            )
        }
    }
}
