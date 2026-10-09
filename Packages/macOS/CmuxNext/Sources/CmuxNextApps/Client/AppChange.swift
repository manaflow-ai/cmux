/// Who caused a change (OWNERSHIP-PRINCIPLES "origin"): the wire values of
/// the `origin` field. The supervisor requires `user` for install and grant
/// changes; hide and unhide accept any origin.
public nonisolated enum AppOrigin: String, Sendable, Hashable, CaseIterable {
    case user, cli, mcp, script, remote
}

/// One scope granted or revoked.
public nonisolated struct AppScopeGrantChange: Sendable, Hashable {
    public var scope: String
    public var granted: Bool

    public init(scope: String, granted: Bool) {
        self.scope = scope
        self.granted = granted
    }
}

/// The fields of one `apps-set`. Absent fields stay as they are.
public nonisolated struct AppChange: Sendable, Hashable {
    public var installed: Bool?
    public var enabled: Bool?
    public var hidden: Bool?
    public var sandboxed: Bool?
    public var grant: AppScopeGrantChange?

    public init(installed: Bool? = nil, enabled: Bool? = nil, hidden: Bool? = nil, sandboxed: Bool? = nil, grant: AppScopeGrantChange? = nil) {
        self.installed = installed
        self.enabled = enabled
        self.hidden = hidden
        self.sandboxed = sandboxed
        self.grant = grant
    }

    public static func install(_ on: Bool) -> AppChange { AppChange(installed: on) }
    public static func enable(_ on: Bool) -> AppChange { AppChange(enabled: on) }
    public static func hide(_ on: Bool) -> AppChange { AppChange(hidden: on) }
    public static func sandbox(_ on: Bool) -> AppChange { AppChange(sandboxed: on) }
    public static func grant(_ scope: String, _ on: Bool) -> AppChange { AppChange(grant: AppScopeGrantChange(scope: scope, granted: on)) }

    /// Install and grant changes need a user gesture (the supervisor refuses
    /// them otherwise with `apps.origin`); the client does not even send them.
    public var requiresUserOrigin: Bool { installed != nil || grant != nil }

    /// What the owner is expected to commit, for the visible projection
    /// until the reply arrives: an install enables the app; a removal also
    /// clears hide and grants (V9: uninstall clears enable, hide and grant
    /// in one commit; the mirror then holds the owner's truth).
    public func applied(to record: AppRecord) -> AppRecord {
        var next = record
        if let installed {
            next.installed = installed
            if installed {
                next.enabled = true
            } else {
                next.hidden = false
                next.grants = []
            }
        }
        if let enabled { next.enabled = enabled }
        if let hidden { next.hidden = hidden }
        if let sandboxed { next.sandboxed = sandboxed }
        if let grant {
            if grant.granted { next.grants.insert(grant.scope) } else { next.grants.remove(grant.scope) }
        }
        return next
    }

    /// The `apps-set` params besides `app`, `idempotency_key` and `origin`.
    public var json: [String: AppJSON] {
        var out: [String: AppJSON] = [:]
        if let installed { out["installed"] = .bool(installed) }
        if let enabled { out["enabled"] = .bool(enabled) }
        if let hidden { out["hidden"] = .bool(hidden) }
        if let sandboxed { out["sandboxed"] = .bool(sandboxed) }
        if let grant { out["grant"] = ["scope": .string(grant.scope), "granted": .bool(grant.granted)] }
        return out
    }
}
