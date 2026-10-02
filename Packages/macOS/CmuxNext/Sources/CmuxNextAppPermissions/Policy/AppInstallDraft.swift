public import CmuxNextApps
public import Foundation

/// One scope on the consent sheet.
public nonisolated struct AppConsentRow: Sendable, Hashable, Identifiable {
    public var scope: String
    /// The manifest's reason, shown under the scope.
    public var reason: String
    public var kind: AppScopeKind
    /// From `scopes` (true) or `optionalScopes` (false).
    public var required: Bool
    /// False for a restricted scope this tier may not hold (shown locked).
    public var holdable: Bool
    /// Checked on the sheet.
    public var on: Bool
    /// The approval mode the scope gets when it is on.
    public var approval: AppScopeApproval

    public var id: String { scope }
}

/// The install consent state for one app: tier defaults (section 4
/// "Default grant at install"), the profile picker and the user's edits.
/// `record()` is the grant the install op writes (revision 1).
public nonisolated struct AppInstallDraft: Sendable, Hashable {
    public var appID: String
    public var tier: AppTier
    public var reviewed: Set<String>
    public private(set) var profile: AppSandboxProfile
    public private(set) var rows: [AppConsentRow]
    /// Scopes the user turned on by hand while Complete sandbox is picked.
    public private(set) var sandboxPicks: Set<String> = []

    /// Tier defaults for a manifest's scopes.
    public init(appID: String, tier: AppTier, required: [AppScopeRequest], optional: [AppScopeRequest],
                reviewed: Set<String> = [], profile: AppSandboxProfile? = nil) {
        self.appID = appID
        self.tier = tier
        self.reviewed = reviewed
        self.profile = profile ?? tier.defaultProfile
        let requiredScopes = Set(required.map(\.scope))
        rows = (required + optional.filter { !requiredScopes.contains($0.scope) }).map { request in
            let kind = AppScopeKind(request.scope)
            let isRequired = requiredScopes.contains(request.scope)
            let holdable = AppPermissionPolicy.mayHold(request.scope, tier: tier, reviewed: reviewed)
            return AppConsentRow(scope: request.scope, reason: request.reason, kind: kind, required: isRequired, holdable: holdable,
                                 on: holdable && isRequired && Self.onByDefault(kind, tier: tier),
                                 approval: Self.defaultApproval(for: request.scope, tier: tier))
        }
    }

    public init(manifest: AppManifest, tier: AppTier, reviewed: Set<String> = [], profile: AppSandboxProfile? = nil) {
        self.init(appID: manifest.id, tier: tier, required: manifest.scopes, optional: manifest.optionalScopes,
                  reviewed: reviewed, profile: profile)
    }

    /// Whether a required scope starts checked: first-party all; Verified
    /// all but `execute` and `external`; unverified read scopes only.
    public static func onByDefault(_ kind: AppScopeKind, tier: AppTier) -> Bool {
        switch tier {
        case .firstParty: true
        case .verified: kind.risk != .execute && kind.risk != .external
        case .unverified: kind.risk == .read
        }
    }

    /// Approval for a scope when turned on: unverified apps ask once per
    /// session for `execute`, `external` and `net:`; everything else runs.
    public static func defaultApproval(for scope: String, tier: AppTier) -> AppScopeApproval {
        let risk = AppScopeKind(scope).risk
        if tier == .unverified, risk == .execute || risk == .external || risk == .network { return .perSession }
        return .always
    }

    /// Whether the row reads as on under the picked profile (Complete
    /// sandbox shows only hand picks).
    public func isOn(_ scope: String) -> Bool {
        guard let row = rows.first(where: { $0.scope == scope }), row.on else { return false }
        return profile != .completeSandbox || sandboxPicks.contains(scope)
    }

    /// Whether the profile lets the user turn the row on at all.
    public func isAvailable(_ scope: String) -> Bool {
        guard let row = rows.first(where: { $0.scope == scope }), row.holdable else { return false }
        return AppPermissionPolicy.profileAllows(scope, profile: profile)
    }

    public mutating func set(_ scope: String, on: Bool) {
        guard let index = rows.firstIndex(where: { $0.scope == scope }) else { return }
        if on, !rows[index].holdable { return }
        if profile == .completeSandbox {
            guard !on || AppPermissionPolicy.profileAllows(scope, profile: .completeSandbox) else { return }
            if on { sandboxPicks.insert(scope) } else { sandboxPicks.remove(scope) }
            if on { rows[index].on = true }
        } else {
            rows[index].on = on
        }
    }

    public mutating func setApproval(_ scope: String, _ approval: AppScopeApproval) {
        guard let index = rows.firstIndex(where: { $0.scope == scope }) else { return }
        if approval == .denied { set(scope, on: false) } else { rows[index].approval = approval }
    }

    public mutating func setProfile(_ profile: AppSandboxProfile) {
        if profile == .completeSandbox, self.profile != .completeSandbox { sandboxPicks = [] }
        self.profile = profile
    }

    /// The install record: checked rows granted with their approval,
    /// unchecked optional rows requestable on first use, unchecked
    /// required rows off.
    public func record() -> AppPermissionRecord {
        var grant = AppGrant()
        for row in rows where row.holdable {
            if row.on {
                grant.scopes[row.scope] = row.approval
            } else if row.required {
                grant.scopes[row.scope] = .denied
            } else {
                grant.requestable.insert(row.scope)
            }
        }
        if profile == .completeSandbox { grant.sandboxPicks = sandboxPicks.filter { grant.scopes[$0].map { $0 != .denied } ?? false } }
        return AppPermissionRecord(appID: appID, tier: tier, reviewed: reviewed, declared: Set(rows.map(\.scope)),
                                   profile: profile, grant: grant)
    }
}
