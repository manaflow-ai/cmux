/// What a committed op emits. `changed` carries the full record, so a
/// mirror converges by keeping the highest revision per app.
/// Wire shapes (app-hide.md section 2): `{"event": "app.changed", "record": {...}}`,
/// `{"event": "app.storage_removed", "app": "..."}`, `{"event": "app.grant_removed", "app": "..."}`.
public nonisolated enum AppStateEvent: Sendable, Hashable {
    case changed(AppInstallState)
    /// Uninstall: the app's storage goes in the same commit.
    case storageRemoved(app: String)
    /// Uninstall: the app's grant goes in the same commit.
    case grantRemoved(app: String)
}

nonisolated extension AppStateEvent: Codable {
    enum CodingKeys: String, CodingKey { case event, record, app }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .event)
        switch name {
        case "app.changed": self = .changed(try c.decode(AppInstallState.self, forKey: .record))
        case "app.storage_removed": self = .storageRemoved(app: try c.decode(String.self, forKey: .app))
        case "app.grant_removed": self = .grantRemoved(app: try c.decode(String.self, forKey: .app))
        default: throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "unknown app state event \(name)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .changed(let record):
            try c.encode("app.changed", forKey: .event)
            try c.encode(record, forKey: .record)
        case .storageRemoved(let app):
            try c.encode("app.storage_removed", forKey: .event)
            try c.encode(app, forKey: .app)
        case .grantRemoved(let app):
            try c.encode("app.grant_removed", forKey: .event)
            try c.encode(app, forKey: .app)
        }
    }
}

/// Why the owner refused an op. Wire shape: `{"code": "...", "origin"?, "source"?}`.
public nonisolated enum AppStateReject: Error, Sendable, Hashable {
    /// The channel may not send this op (installs and hidden access are
    /// user only; no app state op is an MCP tool, a script step or a remote relay).
    case originNotAllowed(AppStateOrigin)
    case notInstalled
    /// Only a team admin removes a team-installed app (members hide or disable it).
    case adminOnly
    /// The idempotency key was used before by this client for a different op.
    case keyReused
    /// A client key with the owner's reserved `default-install:` prefix.
    case reservedKey
    /// A default or team install from a principal that may not make one.
    case sourceNotAllowed(AppInstallSource)

    /// The error code CLI and UI show.
    public var code: String {
        switch self {
        case .originNotAllowed: "app.origin_not_allowed"
        case .notInstalled: "app.not_installed"
        case .adminOnly: "app.admin_only"
        case .keyReused: "idempotency.key_reused"
        case .reservedKey: "idempotency.reserved_key"
        case .sourceNotAllowed: "app.source_not_allowed"
        }
    }
}

nonisolated extension AppStateReject: Codable {
    enum CodingKeys: String, CodingKey { case code, origin, source }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        switch code {
        case "app.origin_not_allowed": self = .originNotAllowed(try c.decode(AppStateOrigin.self, forKey: .origin))
        case "app.not_installed": self = .notInstalled
        case "app.admin_only": self = .adminOnly
        case "idempotency.key_reused": self = .keyReused
        case "idempotency.reserved_key": self = .reservedKey
        case "app.source_not_allowed": self = .sourceNotAllowed(try c.decode(AppInstallSource.self, forKey: .source))
        default: throw DecodingError.dataCorruptedError(forKey: .code, in: c, debugDescription: "unknown reject \(code)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        if case .originNotAllowed(let origin) = self { try c.encode(origin, forKey: .origin) }
        if case .sourceNotAllowed(let source) = self { try c.encode(source, forKey: .source) }
    }
}
