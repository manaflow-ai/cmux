public import Foundation

/// A batch of agent permission rules the user approved once, instead of
/// answering each matching prompt.
///
/// Rules use Claude Code's permission-rule syntax (`Bash(git:*)`,
/// `Edit(//abs/dir/**)`, `WebFetch(domain:example.com)`). Only the cmux app
/// creates grants, after the user approves them, and only the app answers
/// permission requests from them.
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
    /// Every grant expires; see ``AgentPermissionGrantDuration``.
    public var expiresAt: Date
    /// How many permission requests this grant has answered.
    public var useCount: Int
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        rules: [String],
        scope: Scope,
        reason: String? = nil,
        grantedAt: Date = Date(),
        expiresAt: Date,
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
        expiresAt <= now
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

    /// Whether a grant read back from disk is one the app could have
    /// created: unexpired, within the longest duration, with valid rules and
    /// scope. Anything else was hand-written and is dropped.
    func isLoadable(now: Date) -> Bool {
        guard !isExpired(at: now),
              expiresAt <= now.addingTimeInterval(AgentPermissionGrantDuration.maximumSeconds),
              !rules.isEmpty, rules.count <= AgentPermissionGrantProposal.maximumRuleCount,
              rules.allSatisfy(AgentPermissionRuleMatcher.isValid),
              reason.map({ AgentPermissionText.sanitizedReason($0) == $0 }) ?? true else {
            return false
        }
        switch scope {
        case .session(let id):
            return !id.isEmpty && !AgentPermissionText.containsInvisibleOrControl(id)
        case .project(let root):
            return root.hasPrefix("/") && root != "/" && !AgentPermissionText.containsInvisibleOrControl(root)
        }
    }
}
