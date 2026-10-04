public import CmuxNextApps
public import Foundation

/// Pure rules of the app sandbox (first-party-apps.md sections 4 and 5).
/// Effective reach = grant ∩ profile ∩ tier rules. Owners call
/// `effectiveDecision` on every op with the current grant; the supervisor
/// uses the same function to filter early. No state, no I/O.
public nonisolated enum AppPermissionPolicy {
    // MARK: Tier rules

    /// Whether an app of `tier` may hold `scope` at all. Unverified apps
    /// never hold restricted scopes; Verified apps hold only those the
    /// human review approved for this version (`reviewed`).
    public static func mayHold(_ scope: String, tier: AppTier, reviewed: Set<String> = []) -> Bool {
        let kind = AppScopeKind(scope)
        guard kind.isRestricted else { return true }
        switch tier {
        case .firstParty: return true
        case .verified: return reviewed.contains(scope) || (scope.hasPrefix("fs:write:") && reviewed.contains("fs:write"))
        case .unverified: return false
        }
    }

    /// The scopes of `scopes` that `tier` may never hold, given `reviewed`.
    public static func refusedScopes(_ scopes: Set<String>, for tier: AppTier, reviewed: Set<String> = []) -> Set<String> {
        scopes.filter { !mayHold($0, tier: tier, reviewed: reviewed) }
    }

    // MARK: Profile cap

    /// The approval `profile` leaves for `scope` granted with `approval`,
    /// or nil when the profile refuses the scope outright. Never wider
    /// than `approval`. `picks` is the grant's Complete sandbox picks.
    public static func cap(_ approval: AppScopeApproval, scope: String, profile: AppSandboxProfile,
                           picks: Set<String>) -> AppScopeApproval? {
        guard profileAllows(scope, profile: profile) else { return nil }
        let kind = AppScopeKind(scope)
        switch profile {
        case .standard:
            return approval
        case .contained:
            switch kind.risk {
            case .read, .write: return approval
            case .network: return approval.capped(at: .perSession)
            case .execute, .external: return approval.capped(at: .perCall)
            }
        case .completeSandbox:
            return picks.contains(scope) ? approval : nil
        }
    }

    /// Whether `profile` can ever allow `scope`, whatever the grant says:
    /// Contained has no files, no agents and no synced storage; Complete
    /// sandbox also has no network.
    public static func profileAllows(_ scope: String, profile: AppSandboxProfile) -> Bool {
        let kind = AppScopeKind(scope)
        switch profile {
        case .standard:
            return true
        case .contained:
            return !kind.isFiles && kind.axis != .agents && scope != "storage:synced"
        case .completeSandbox:
            return !kind.isFiles && !kind.isNetwork && kind.axis != .agents && scope != "storage:synced"
        }
    }

    /// grant ∩ profile ∩ tier: the grant an owner effectively enforces.
    /// Every scope in the result is in `grant` with an approval no wider;
    /// selectors and file roots are the grant's (Contained and Complete
    /// sandbox drop the roots).
    public static func capped(_ grant: AppGrant, profile: AppSandboxProfile, tier: AppTier,
                              reviewed: Set<String> = []) -> AppGrant {
        var result = grant
        result.scopes = [:]
        guard !grant.disabled else {
            result.fileRoots = []
            result.requestable = []
            return result
        }
        for (scope, approval) in grant.scopes where mayHold(scope, tier: tier, reviewed: reviewed) {
            guard let capped = cap(approval, scope: scope, profile: profile, picks: grant.sandboxPicks) else { continue }
            result.scopes[scope] = capped
        }
        result.requestable = grant.requestable.filter {
            mayHold($0, tier: tier, reviewed: reviewed) && profileAllows($0, profile: profile) && profile != .completeSandbox
        }
        if profile != .standard { result.fileRoots = [] }
        return result
    }

    // MARK: Decision

    /// Whether `op` with `params` runs, asks or is refused for an app with
    /// `grant` under `profile` and `tier`. Order: disabled, table (never,
    /// unsupported), tier, profile, grant, resources, approval.
    public static func effectiveDecision(op: String, params: AppJSON, grant: AppGrant, profile: AppSandboxProfile,
                                         tier: AppTier, scopeTable: AppScopeTable, reviewed: Set<String> = [],
                                         session: AppSessionApprovals = .none) -> AppPermissionDecision {
        func refuse(_ reason: AppRefusal.Reason, _ scope: String? = nil) -> AppPermissionDecision {
            .refuse(AppRefusal(reason: reason, op: op, scope: scope))
        }
        if grant.disabled { return refuse(.disabled) }
        let scope: String
        let root: String?
        switch AppScopeRequirement.resolve(op: op, params: params, table: scopeTable) {
        case .own: return .allow
        case .never: return refuse(.never)
        case .unsupported: return refuse(.unsupported)
        case .invalidParams: return refuse(.invalidParams)
        case .scope(let needed, let neededRoot):
            scope = needed
            root = neededRoot
        }
        guard mayHold(scope, tier: tier, reviewed: reviewed) else { return refuse(.tierRestricted, scope) }
        guard profileAllows(scope, profile: profile) else { return refuse(.profile, scope) }
        guard let held = grant.held(scope) else {
            if grant.requestable.contains(scope), profile != .completeSandbox { return .ask(.firstUse, scope: scope) }
            return refuse(.scopeMissing, scope)
        }
        if held.approval == .denied { return refuse(.scopeMissing, scope) }
        guard withinResources(params: params, root: root, scope: scope, grant: grant) else {
            return refuse(.outsideResources, scope)
        }
        guard let approval = cap(held.approval, scope: held.scope, profile: profile, picks: grant.sandboxPicks) else {
            return refuse(.profile, scope)
        }
        switch approval {
        case .always: return .allow
        case .perSession: return session.covers(held.scope, grant: grant) ? .allow : .ask(.perSession, scope: held.scope)
        case .perCall: return .ask(.perCall, scope: held.scope)
        case .denied: return refuse(.scopeMissing, scope)
        }
    }

    /// The decision for a call admitted at an earlier grant revision. A
    /// call made before the grant last narrowed is refused (`grant.revoked`,
    /// retryable); otherwise it is checked again under the current grant.
    public static func admit(_ call: AppPendingCall, grant: AppGrant, profile: AppSandboxProfile, tier: AppTier,
                             scopeTable: AppScopeTable, reviewed: Set<String> = [],
                             session: AppSessionApprovals = .none) -> AppPermissionDecision {
        if call.grantRevision < grant.narrowedAt {
            return .refuse(AppRefusal(reason: .revoked, op: call.op))
        }
        return effectiveDecision(op: call.op, params: call.params, grant: grant, profile: profile, tier: tier,
                                 scopeTable: scopeTable, reviewed: reviewed, session: session)
    }

    /// Selectors and file roots: an op that names a workspace, room or
    /// machine outside the selection, or a file root the grant does not
    /// hold (or holds read-only for a write), is outside the grant.
    static func withinResources(params: AppJSON, root: String?, scope: String, grant: AppGrant) -> Bool {
        let selectors = grant.selectors
        func inside(_ keys: [String], _ allowed: Set<String>?) -> Bool {
            guard let allowed else { return true }
            return keys.compactMap { params[$0]?.stringValue }.allSatisfy(allowed.contains)
        }
        guard inside(["workspace", "workspace_id"], selectors.workspaces),
              inside(["room", "room_id"], selectors.rooms),
              inside(["machine", "machine_id", "host"], selectors.machines) else { return false }
        guard let root else { return true }
        guard let granted = grant.fileRoots.first(where: { $0.id == root }) else { return false }
        return AppScopeKind(scope).risk == .read || granted.writable
    }
}
