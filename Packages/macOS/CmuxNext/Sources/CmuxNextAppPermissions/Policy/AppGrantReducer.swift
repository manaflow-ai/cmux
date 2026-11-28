public import Foundation

public nonisolated enum AppGrantRejection: Error, Sendable, Hashable {
    /// Only the user changes grants; a team admin only narrows them.
    case originNotAllowed(AppGrantChangeOrigin)
    case tierRestricted(scope: String)
    case undeclared(scope: String)
    /// A first-use answer for a scope the app may not ask for (or while
    /// Complete sandbox is on, where nothing prompts).
    case notRequestable(scope: String)
}

/// Applies grant changes. Pure: `(record, change, origin) -> record'`.
/// Every effective change bumps `grant.revision`; a change that removes
/// any reach also sets `grant.narrowedAt`, which voids pending calls and
/// session answers from older revisions.
public nonisolated enum AppGrantReducer {
    public static func apply(_ change: AppGrantChange, to record: AppPermissionRecord,
                             origin: AppGrantChangeOrigin) -> Result<AppPermissionRecord, AppGrantRejection> {
        guard origin == .user || origin == .teamAdmin else { return .failure(.originNotAllowed(origin)) }
        var next = record
        var narrows = false
        var grant = record.grant
        switch change {
        case .setApproval(let scope, let approval):
            guard record.declared.contains(scope) else { return .failure(.undeclared(scope: scope)) }
            if approval != .denied, !AppPermissionPolicy.mayHold(scope, tier: record.tier, reviewed: record.reviewed) {
                return .failure(.tierRestricted(scope: scope))
            }
            let old = grant.scopes[scope] ?? .denied
            narrows = approval < old || (approval == .denied && grant.requestable.contains(scope))
            grant.scopes[scope] = approval
            grant.requestable.remove(scope)
            if record.profile == .completeSandbox {
                if approval == .denied {
                    narrows = narrows || grant.sandboxPicks.contains(scope)
                    grant.sandboxPicks.remove(scope)
                } else if AppPermissionPolicy.profileAllows(scope, profile: .completeSandbox) {
                    grant.sandboxPicks.insert(scope)
                }
            }
        case .setSelectors(let selectors):
            narrows = !record.grant.selectors.isWithin(selectors)
            grant.selectors = selectors
        case .addFileRoot(let root):
            if root.writable, !AppPermissionPolicy.mayHold("fs:write", tier: record.tier, reviewed: record.reviewed) {
                return .failure(.tierRestricted(scope: "fs:write"))
            }
            if let old = grant.fileRoots.firstIndex(where: { $0.id == root.id }) {
                narrows = grant.fileRoots[old].writable && !root.writable
                grant.fileRoots[old] = root
            } else {
                grant.fileRoots.append(root)
            }
        case .removeFileRoot(let id):
            narrows = grant.fileRoots.contains { $0.id == id }
            grant.fileRoots.removeAll { $0.id == id }
        case .setProfile(let profile):
            narrows = profile > record.profile
            if profile == .completeSandbox, record.profile != .completeSandbox {
                grant.sandboxPicks = []
            }
            next.profile = profile
        case .answerFirstUse(let scope, let answer):
            guard record.profile != .completeSandbox, grant.requestable.contains(scope), grant.scopes[scope] == nil else {
                return .failure(.notRequestable(scope: scope))
            }
            switch answer {
            case .allowOnce:
                return .success(record)
            case .allow:
                guard AppPermissionPolicy.mayHold(scope, tier: record.tier, reviewed: record.reviewed) else {
                    return .failure(.tierRestricted(scope: scope))
                }
                grant.scopes[scope] = AppInstallDraft.defaultApproval(for: scope, tier: record.tier)
            case .deny:
                grant.scopes[scope] = .denied
                narrows = true
            }
            grant.requestable.remove(scope)
        case .revokeAll:
            grant.scopes = grant.scopes.mapValues { _ in .denied }
            grant.requestable = []
            grant.fileRoots = []
            grant.sandboxPicks = []
            grant.disabled = true
            narrows = true
        case .enable:
            grant.disabled = false
        }
        if origin == .teamAdmin, !narrows { return .failure(.originNotAllowed(origin)) }
        guard grant != record.grant || next.profile != record.profile else { return .success(record) }
        grant.revision = record.grant.revision + 1
        if narrows { grant.narrowedAt = grant.revision }
        next.grant = grant
        return .success(next)
    }
}
