/// A typed op on one user's app state (catalog family `app`, owner
/// `UserDO` / `TeamDO`). `key` is the client-chosen idempotency key.
/// Wire shape (app-hide.md section 2):
/// `{"op": "app.hide", "idempotency_key": "...", "params": {"app": "...", ...}}`.
public nonisolated struct AppStateOp: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
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

nonisolated extension AppStateOp: Codable {
    enum CodingKeys: String, CodingKey { case op, key = "idempotency_key", params }
    enum ParamKeys: String, CodingKey { case app, source, confirmed, cli, mcp, automations }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        let p = try c.nestedContainer(keyedBy: ParamKeys.self, forKey: .params)
        app = try p.decode(String.self, forKey: .app)
        let name = try c.decode(String.self, forKey: .op)
        switch name {
        case "app.install": kind = .install(try p.decode(AppInstallSource.self, forKey: .source))
        case "app.remove": kind = .remove(confirmed: try p.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false)
        case "app.enable": kind = .enable
        case "app.disable": kind = .disable
        case "app.hide": kind = .hide
        case "app.unhide": kind = .unhide
        case "app.set_hidden_access":
            kind = .setHiddenAccess(cli: try p.decodeIfPresent(Bool.self, forKey: .cli), mcp: try p.decodeIfPresent(Bool.self, forKey: .mcp),
                                    automations: try p.decodeIfPresent(Bool.self, forKey: .automations))
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown app state op \(name)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(opName, forKey: .op)
        try c.encode(key, forKey: .key)
        var p = c.nestedContainer(keyedBy: ParamKeys.self, forKey: .params)
        try p.encode(app, forKey: .app)
        switch kind {
        case .install(let source): try p.encode(source, forKey: .source)
        case .remove(let confirmed): try p.encode(confirmed, forKey: .confirmed)
        case .setHiddenAccess(let cli, let mcp, let automations):
            try p.encodeIfPresent(cli, forKey: .cli)
            try p.encodeIfPresent(mcp, forKey: .mcp)
            try p.encodeIfPresent(automations, forKey: .automations)
        case .enable, .disable, .hide, .unhide: break
        }
    }
}

/// The channel an op came through, with the OWNERSHIP-PRINCIPLES names
/// (`user | cli | mcp | script | remote`), plus `system` for the owner's
/// own first-launch default installs (never accepted from a request).
public nonisolated enum AppStateOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case user
    case cli
    case mcp
    /// Automations and scripts.
    case script
    /// Another client relayed from a remote machine.
    case remote
    case system
}

/// Who sends an op: the authenticated client (install id; scopes the
/// idempotency keys), the channel, and whether the principal is an admin of
/// the team that installed the app. Owners take all three from the
/// connection, never from the request body.
public nonisolated struct AppStateActor: Sendable, Hashable, Codable {
    public var client: String
    public var origin: AppStateOrigin
    public var teamAdmin: Bool

    public init(client: String = "local", origin: AppStateOrigin, teamAdmin: Bool = false) {
        self.client = client
        self.origin = origin
        self.teamAdmin = teamAdmin
    }

    public static let user = AppStateActor(origin: .user)
    public static let cli = AppStateActor(origin: .cli)
    public static let system = AppStateActor(client: "owner", origin: .system)
}
