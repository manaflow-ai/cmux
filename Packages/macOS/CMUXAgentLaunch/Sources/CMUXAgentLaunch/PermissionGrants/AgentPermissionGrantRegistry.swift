public import Foundation

/// The app's in-memory authority for approved grants.
///
/// It loads the store once, adds grants only from the approval path, and
/// answers `permissions.match` from memory, counting each use. Editing the
/// file while the app runs changes nothing; the next launch re-validates it.
/// It also admits one approval request at a time.
public final class AgentPermissionGrantRegistry: @unchecked Sendable {
    private let store: AgentPermissionGrantStore
    private let lock = NSLock()
    private var grants: [AgentPermissionGrant]
    private var approvalPending = false

    public init(store: AgentPermissionGrantStore, now: Date = Date()) {
        self.store = store
        self.grants = store.grants(now: now)
    }

    /// Active grants, oldest first.
    public func activeGrants(now: Date = Date()) -> [AgentPermissionGrant] {
        lock.withLock { grants.filter { !$0.isExpired(at: now) } }
    }

    /// Adds an approved grant and saves. Nothing changes when saving fails.
    public func add(_ grant: AgentPermissionGrant, now: Date = Date()) throws {
        try lock.withLock {
            let updated = grants.filter { !$0.isExpired(at: now) } + [grant]
            try store.save(updated)
            grants = updated
        }
    }

    /// Removes one grant, or every grant when `id` is `nil`.
    /// - Returns: How many grants were removed.
    @discardableResult
    public func revoke(id: UUID?, now: Date = Date()) throws -> Int {
        try lock.withLock {
            let active = grants.filter { !$0.isExpired(at: now) }
            let updated = active.filter { id != nil && $0.id != id }
            try store.save(updated)
            grants = updated
            return active.count - updated.count
        }
    }

    /// Whether an active grant allows `request` from `sessionID`. A match
    /// counts one use against the first grant that covers it.
    public func answer(
        _ request: AgentPermissionRequest,
        sessionID: String?,
        now: Date = Date(),
        home: String = NSHomeDirectory()
    ) -> Bool {
        lock.withLock {
            guard !AgentPermissionRuleMatcher.userAnswerTools.contains(request.toolName),
                  let index = grants.firstIndex(where: { grant in
                      grant.covers(sessionID: sessionID, cwd: request.cwd, now: now)
                          && grant.rules.contains { AgentPermissionRuleMatcher.allows(rule: $0, request: request, home: home) }
                  }) else {
                return false
            }
            grants[index].useCount += 1
            grants[index].lastUsedAt = now
            // Use counts are an audit aid; a failed save doesn't undo the answer.
            try? store.save(grants.filter { !$0.isExpired(at: now) })
            return true
        }
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
