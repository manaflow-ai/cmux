/// A typed op on one user's app state (catalog family `app`, owner
/// `UserDO` / `TeamDO`). `key` is the client-chosen idempotency key.
public nonisolated struct AppStateOp: Sendable, Hashable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
        case install(AppInstallSource)
        /// `confirmed: false` on a default-installed app hides it instead.
        case remove(confirmed: Bool)
        case enable
        case disable
        case hide
        case unhide
        /// nil leaves a channel as it is.
        case setHiddenAccess(cli: Bool?, mcp: Bool?, automations: Bool?)
    }

    public var key: String
    public var app: String
    public var kind: Kind

    public init(key: String, app: String, kind: Kind) {
        self.key = key
        self.app = app
        self.kind = kind
    }

    /// The catalog op name (`app.hide`).
    public var opName: String {
        switch kind {
        case .install: "app.install"
        case .remove: "app.remove"
        case .enable: "app.enable"
        case .disable: "app.disable"
        case .hide: "app.hide"
        case .unhide: "app.unhide"
        case .setHiddenAccess: "app.set_hidden_access"
        }
    }
}

/// The channel an op came through (`origin`, OWNERSHIP-PRINCIPLES), plus
/// `system` for first-launch default installs by the owner itself.
public nonisolated enum AppStateOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case user
    case cli
    case mcp
    case automation
    case remote
    case system
}

/// Who sends an op: the channel and whether the principal is an admin of
/// the team that installed the app (owners look the class up; it never
/// comes from the request body).
public nonisolated struct AppStateActor: Sendable, Hashable, Codable {
    public var origin: AppStateOrigin
    public var teamAdmin: Bool

    public init(origin: AppStateOrigin, teamAdmin: Bool = false) {
        self.origin = origin
        self.teamAdmin = teamAdmin
    }

    public static let user = AppStateActor(origin: .user)
    public static let cli = AppStateActor(origin: .cli)
    public static let system = AppStateActor(origin: .system)
}
