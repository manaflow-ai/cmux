public import Foundation

/// The app's in-memory authority for approved grants.
///
/// Grants are added only from the approval path and never touch disk: they
/// last until they expire, are revoked, or cmux quits. The registry answers
/// `permissions.match` from memory, counting each use, and admits one
/// approval request at a time.
public final class AgentPermissionGrantRegistry: @unchecked Sendable {
    private let matcher: AgentPermissionRuleMatcher
    private let lock = NSLock()
    private var grants: [AgentPermissionGrant] = []
    private var approvalPending = false

    public init(matcher: AgentPermissionRuleMatcher = AgentPermissionRuleMatcher()) {
        self.matcher = matcher
    }

    /// Active grants, oldest first.
    public func activeGrants(now: Date = Date()) -> [AgentPermissionGrant] {
        lock.withLock { grants.filter { !$0.isExpired(at: now) } }
    }

    /// Adds an approved grant.
    public func add(_ grant: AgentPermissionGrant, now: Date = Date()) {
        lock.withLock {
            grants = grants.filter { !$0.isExpired(at: now) } + [grant]
        }
    }

    /// Removes one grant, or every grant when `id` is `nil`.
    /// - Returns: How many active grants were removed.
    @discardableResult
    public func revoke(id: UUID?, now: Date = Date()) -> Int {
        lock.withLock {
            let active = grants.filter { !$0.isExpired(at: now) }
            grants = active.filter { id != nil && $0.id != id }
            return active.count - grants.count
        }
    }

    /// Whether an active grant allows `request` from `sessionID`. A match
    /// counts one use against the first grant that covers it.
    public func answer(_ request: AgentPermissionRequest, sessionID: String?, now: Date = Date()) -> Bool {
        lock.withLock {
            guard !AgentPermissionRuleMatcher.userAnswerTools.contains(request.toolName),
                  let index = grants.firstIndex(where: { grant in
                      grant.covers(sessionID: sessionID, cwd: request.cwd, now: now)
                          && grant.rules.contains { matcher.allows(rule: $0, request: request) }
                  }) else {
                return false
            }
            grants[index].useCount += 1
            grants[index].lastUsedAt = now
            return true
        }
    }

    /// The `permissions.match` answer for parameters from
    /// ``AgentPermissionRequest/claudeMatchParams(hookPayload:)``.
    public func answer(matchParams params: [String: Any], now: Date = Date()) -> Bool {
        guard let request = AgentPermissionRequest(claudeHookPayload: params) else { return false }
        return answer(request, sessionID: params["session_id"] as? String, now: now)
    }

    /// Claims the single approval slot.
    /// - Returns: `false` when another request is already waiting on the user.
    public func beginApproval() -> Bool {
        lock.withLock {
            guard !approvalPending else { return false }
            approvalPending = true
            return true
        }
    }

    public func endApproval() {
        lock.withLock { approvalPending = false }
    }
}
