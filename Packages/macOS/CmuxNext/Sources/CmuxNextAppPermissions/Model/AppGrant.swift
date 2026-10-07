import Foundation

/// One app's grant (identity-and-permissions.md section 4, grantee
/// `app:<id>`): scopes with an approval mode each, resource selectors and
/// file roots. Owned by `UserDO` / `TeamDO`; this value is the projection
/// the supervisor and every op owner check. Changes go only through
/// `AppGrantReducer` (user origin), which bumps `revision`.
public nonisolated struct AppGrant: Sendable, Hashable, Codable {
    /// Granted scopes by scope string (`workspace:read`, `net:api.example.com`).
    /// A scope the user turned off stays here as `.denied` so the app is
    /// never asked again for it.
    public var scopes: [String: AppScopeApproval]
    /// Optional scopes from the manifest the app may ask for on first use.
    public var requestable: Set<String>
    /// Narrows every op that names a workspace, room or machine.
    public var selectors: AppResourceSelectors
    /// Folders the user picked (opaque ids; the app never sees a path).
    public var fileRoots: [AppFileRoot]
    /// Scopes the user turned on by hand while Complete sandbox is on.
    /// Cleared on every switch into Complete sandbox.
    public var sandboxPicks: Set<String>
    /// "Revoke all and disable": nothing runs until the user enables the app.
    public var disabled: Bool
    /// Increments on every change.
    public var revision: UInt64
    /// The revision of the last change that narrowed reach. A pending call
    /// stamped with an older revision is refused (`grant.revoked`).
    public var narrowedAt: UInt64

    public init(scopes: [String: AppScopeApproval] = [:], requestable: Set<String> = [], selectors: AppResourceSelectors = .any,
                fileRoots: [AppFileRoot] = [], sandboxPicks: Set<String> = [], disabled: Bool = false,
                revision: UInt64 = 1, narrowedAt: UInt64 = 0) {
        self.scopes = scopes
        self.requestable = requestable
        self.selectors = selectors
        self.fileRoots = fileRoots
        self.sandboxPicks = sandboxPicks
        self.disabled = disabled
        self.revision = revision
        self.narrowedAt = narrowedAt
    }

    /// The approval of the held scope that covers `scope`: an exact entry,
    /// a `net:*.domain` pattern for a host, or `integration:<p>` for its
    /// `:read` form. Nil when nothing covers it.
    public func held(_ scope: String) -> (scope: String, approval: AppScopeApproval)? {
        if let approval = scopes[scope] { return (scope, approval) }
        let kind = AppScopeKind(scope)
        if let host = kind.host {
            let match = scopes.filter { key, _ in
                let pattern = AppScopeKind(key)
                return pattern.isNetwork && pattern.level.hasPrefix("*.") && host.hasSuffix(String(pattern.level.dropFirst(1)))
            }.max { $0.value < $1.value }
            return match.map { ($0.key, $0.value) }
        }
        if kind.family == "integration", scope.hasSuffix(":read") {
            let write = String(scope.dropLast(":read".count))
            if let approval = scopes[write] { return (write, approval) }
        }
        return nil
    }

    /// Scopes that are on (not `.denied`).
    public var activeScopes: Set<String> { Set(scopes.filter { $0.value != .denied }.keys) }
}

/// Resource selectors (section 5.1): nil means any. An op whose params
/// name a workspace, room or machine outside a non-nil set is refused.
public nonisolated struct AppResourceSelectors: Sendable, Hashable, Codable {
    public var workspaces: Set<String>?
    public var rooms: Set<String>?
    public var machines: Set<String>?

    public static let any = AppResourceSelectors()

    public init(workspaces: Set<String>? = nil, rooms: Set<String>? = nil, machines: Set<String>? = nil) {
        self.workspaces = workspaces
        self.rooms = rooms
        self.machines = machines
    }

    /// Whether `self` reaches no resource that `other` does not.
    public func isWithin(_ other: AppResourceSelectors) -> Bool {
        func within(_ a: Set<String>?, _ b: Set<String>?) -> Bool {
            guard let b else { return true }
            guard let a else { return false }
            return a.isSubset(of: b)
        }
        return within(workspaces, other.workspaces) && within(rooms, other.rooms) && within(machines, other.machines)
    }

    /// The intersection (narrower of both, per axis).
    public func intersection(_ other: AppResourceSelectors) -> AppResourceSelectors {
        func meet(_ a: Set<String>?, _ b: Set<String>?) -> Set<String>? {
            switch (a, b) {
            case (nil, nil): nil
            case (let a?, nil): a
            case (nil, let b?): b
            case (let a?, let b?): a.intersection(b)
            }
        }
        return AppResourceSelectors(workspaces: meet(workspaces, other.workspaces), rooms: meet(rooms, other.rooms),
                                    machines: meet(machines, other.machines))
    }
}

/// A folder granted to the app (section 5.3). `id` is opaque; the host
/// keeps the security-scoped bookmark and resolves paths inside the root.
public nonisolated struct AppFileRoot: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// A workspace's folder (`fs:read:workspace`).
        case workspaceFolder
        /// A folder the user picked in the host file panel.
        case bookmark
    }

    public var id: String
    public var kind: Kind
    /// Host-side display name (the folder name); never sent to the app.
    public var label: String
    /// Writes need `fs:write` too (restricted).
    public var writable: Bool

    public init(id: String, kind: Kind, label: String, writable: Bool = false) {
        self.id = id
        self.kind = kind
        self.label = label
        self.writable = writable
    }
}
