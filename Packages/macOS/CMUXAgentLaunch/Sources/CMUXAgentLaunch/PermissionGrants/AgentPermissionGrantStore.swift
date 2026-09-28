import Darwin
public import Foundation

/// The approved permission grants, in an owner-only JSON file that the app
/// writes and hook processes read.
///
/// Every read-modify-write holds an exclusive `flock` on a sibling lock file,
/// so concurrent hook processes recording uses never lose one another's
/// updates. Expired grants are dropped on every write.
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

    private struct File: Codable {
        var version = 1
        var grants: [AgentPermissionGrant]
    }

    /// Active grants, oldest first.
    public func grants(now: Date = Date()) -> [AgentPermissionGrant] {
        read().filter { !$0.isExpired(at: now) }
    }

    public func add(_ grant: AgentPermissionGrant, now: Date = Date()) throws {
        try update(now: now) { $0.append(grant) }
    }

    /// Removes one grant, or every grant when `id` is `nil`.
    /// - Returns: How many grants were removed.
    @discardableResult
    public func revoke(id: UUID?, now: Date = Date()) throws -> Int {
        var removed = 0
        try update(now: now) { grants in
            let before = grants.count
            grants.removeAll { id == nil || $0.id == id }
            removed = before - grants.count
        }
        return removed
    }

    /// The first active grant with a rule allowing `request` from `sessionID`,
    /// and that rule.
    public func match(
        _ request: AgentPermissionRequest,
        sessionID: String?,
        now: Date = Date()
    ) -> (grant: AgentPermissionGrant, rule: String)? {
        for grant in grants(now: now) where grant.covers(sessionID: sessionID, cwd: request.cwd, now: now) {
            if let rule = grant.rules.first(where: { AgentPermissionRuleMatcher.allows(rule: $0, request: request) }) {
                return (grant, rule)
            }
        }
        return nil
    }

    /// Counts one answered request against a grant, for the audit list.
    public func recordUse(of id: UUID, now: Date = Date()) throws {
        try update(now: now) { grants in
            guard let index = grants.firstIndex(where: { $0.id == id }) else { return }
            grants[index].useCount += 1
            grants[index].lastUsedAt = now
        }
    }

    private func read() -> [AgentPermissionGrant] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data).grants) ?? []
    }

    private func update(now: Date, _ mutate: (inout [AgentPermissionGrant]) -> Void) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = fileURL.path + ".lock"
        let lock = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
        defer { flock(lock, LOCK_UN) }

        var grants = read().filter { !$0.isExpired(at: now) }
        mutate(&grants)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(grants: grants))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
