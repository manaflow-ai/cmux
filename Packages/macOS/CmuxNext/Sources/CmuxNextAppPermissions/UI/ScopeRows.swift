import Foundation

/// One scope as every presentation shows it.
struct ScopeRowState: Identifiable, Hashable {
    enum Lock: Hashable {
        /// The tier may not hold this restricted scope.
        case tier
        /// The sandbox profile blocks it.
        case profile
    }

    var scope: String
    var title: String
    var reason: String
    var kind: AppScopeKind
    var required: Bool
    var on: Bool
    /// The effective approval while on (after the profile cap).
    var approval: AppScopeApproval
    /// The widest approval the profile leaves (`.denied` when locked).
    var maxApproval: AppScopeApproval
    var lock: Lock?

    var id: String { scope }
    var tone: AppRiskTone { kind.risk.tone }
    /// The matrix cell that is selected.
    var selected: AppScopeApproval { on ? approval : .denied }
}

/// What a row control asks for; each surface maps it to its model.
struct ScopeRowActions {
    var setOn: @MainActor (String, Bool) -> Void
    var setApproval: @MainActor (String, AppScopeApproval) -> Void
}

/// Builds rows from a consent draft or an installed record.
enum ScopeRows {
    static func consent(_ draft: AppInstallDraft) -> [ScopeRowState] {
        draft.rows.map { row in
            let available = draft.isAvailable(row.scope)
            let max = available ? AppPermissionPolicy.cap(.always, scope: row.scope, profile: draft.profile, picks: [row.scope]) ?? .denied : .denied
            return ScopeRowState(scope: row.scope, title: AppScopeStrings.title(row.scope), reason: row.reason, kind: row.kind,
                                 required: row.required, on: available && draft.isOn(row.scope), approval: row.approval.capped(at: max),
                                 maxApproval: max, lock: lock(holdable: row.holdable, available: available))
        }
    }

    static func settings(_ record: AppPermissionRecord, listing: AppPermissionsListing) -> [ScopeRowState] {
        let requiredScopes = Set(listing.required.map(\.scope))
        return (listing.required + listing.optional.filter { !requiredScopes.contains($0.scope) }).map { request in
            let scope = request.scope
            let holdable = AppPermissionPolicy.mayHold(scope, tier: record.tier, reviewed: record.reviewed)
            let available = holdable && AppPermissionPolicy.profileAllows(scope, profile: record.profile) && !record.grant.disabled
            let max = available ? AppPermissionPolicy.cap(.always, scope: scope, profile: record.profile, picks: [scope]) ?? .denied : .denied
            let granted = record.grant.scopes[scope] ?? .denied
            let picked = record.profile != .completeSandbox || record.grant.sandboxPicks.contains(scope)
            let on = available && granted != .denied && picked
            let approval = on ? granted.capped(at: max) : AppInstallDraft.defaultApproval(for: scope, tier: record.tier).capped(at: max)
            return ScopeRowState(scope: scope, title: AppScopeStrings.title(scope), reason: request.reason, kind: AppScopeKind(scope),
                                 required: requiredScopes.contains(scope), on: on, approval: approval, maxApproval: max,
                                 lock: lock(holdable: holdable, available: available || record.grant.disabled))
        }
    }

    /// Rows by axis in `AppScopeAxis` order, mildest first inside a group.
    static func grouped(_ rows: [ScopeRowState]) -> [(AppScopeAxis, [ScopeRowState])] {
        AppScopeAxis.allCases.compactMap { axis in
            let members = rows.filter { $0.kind.axis == axis }.sorted { ($0.kind.risk, $0.scope) < ($1.kind.risk, $1.scope) }
            return members.isEmpty ? nil : (axis, members)
        }
    }

    /// Rows by risk, most dangerous first.
    static func byRisk(_ rows: [ScopeRowState]) -> [ScopeRowState] {
        rows.sorted { ($1.kind.risk, $0.scope) < ($0.kind.risk, $1.scope) }
    }

    private static func lock(holdable: Bool, available: Bool) -> ScopeRowState.Lock? {
        if !holdable { return .tier }
        return available ? nil : .profile
    }
}
