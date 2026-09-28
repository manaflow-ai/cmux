public import Foundation

/// A batch of agent permission rules the user approved once, instead of
/// answering each matching prompt.
///
/// Rules use Claude Code's permission-rule syntax (`Bash(git:*)`,
/// `Edit(//abs/dir/**)`, `WebFetch(domain:example.com)`). Only the cmux app
/// creates grants, after the user approves them.
public struct AgentPermissionGrant: Codable, Sendable, Equatable, Identifiable {
    /// Who a grant covers.
    public enum Scope: Codable, Sendable, Equatable {
        /// One agent session, by the session id its hooks report.
        case session(id: String)
        /// Every session whose working directory is `root` or below it.
        case project(root: String)
    }

    public var id: UUID
    public var rules: [String]
    public var scope: Scope
    /// Why the grant was requested, shown in the approval dialog and audit list.
    public var reason: String?
    public var grantedAt: Date
    /// `nil` means until revoked.
    public var expiresAt: Date?
    /// How many permission requests this grant has answered.
    public var useCount: Int
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        rules: [String],
        scope: Scope,
        reason: String? = nil,
        grantedAt: Date = Date(),
        expiresAt: Date?,
        useCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.rules = rules
        self.scope = scope
        self.reason = reason
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// Whether the grant covers a request from `sessionID` running in `cwd`.
    public func covers(sessionID: String?, cwd: String?, now: Date) -> Bool {
        guard !isExpired(at: now) else { return false }
        switch scope {
        case .session(let id):
            return sessionID == id
        case .project(let root):
            guard let cwd else { return false }
            return AgentPermissionPath.isSameOrDescendant(cwd, of: root)
        }
    }
}

/// Path comparison for grants: absolute, standardized, symlinks resolved.
enum AgentPermissionPath {
    /// Resolves symlinks through the deepest existing ancestor, so a file
    /// that doesn't exist yet compares like its existing directory.
    static func canonical(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        var existing = URL(fileURLWithPath: expanded).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }

    static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        guard let path = canonical(path), let root = canonical(root) else { return false }
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
