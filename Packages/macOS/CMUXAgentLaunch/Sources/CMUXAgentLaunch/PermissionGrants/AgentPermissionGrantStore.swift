public import Foundation

/// The cmux app's persistence for approved grants: an owner-only JSON file.
///
/// Only the app reads and writes it, through
/// ``AgentPermissionGrantRegistry``; hooks ask the app over the socket
/// instead. The file is untrusted on load: grants that fail
/// ``AgentPermissionGrant/isLoadable(matcher:now:)`` (no expiry, an expiry past the
/// longest duration, invalid rules or scope) are dropped.
public struct AgentPermissionGrantStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/.cmuxterm/agent-permission-grants.json`.
    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("agent-permission-grants.json", isDirectory: false)
    }

    private struct File: Encodable {
        var version = 1
        var grants: [AgentPermissionGrant]
    }

    private struct LoadedFile: Decodable {
        var grants: [LoadedGrant]
    }

    /// One grant, or `nil` when it doesn't decode, so one bad entry never
    /// discards the rest.
    private struct LoadedGrant: Decodable {
        var grant: AgentPermissionGrant?

        init(from decoder: any Decoder) throws {
            grant = try? AgentPermissionGrant(from: decoder)
        }
    }

    /// The loadable grants on disk, oldest first.
    public func grants(
        matcher: AgentPermissionRuleMatcher = AgentPermissionRuleMatcher(),
        now: Date = Date()
    ) -> [AgentPermissionGrant] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? decoder.decode(LoadedFile.self, from: data).grants) ?? []
        return loaded.compactMap(\.grant).filter { $0.isLoadable(matcher: matcher, now: now) }
    }

    /// Replaces the file with `grants`, owner-only.
    public func save(_ grants: [AgentPermissionGrant]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(grants: grants))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
