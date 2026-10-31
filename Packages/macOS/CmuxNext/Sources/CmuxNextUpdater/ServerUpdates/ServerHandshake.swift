import Foundation

/// What a server said about itself when the app connected: its build, protocol version and the
/// capabilities it serves. Behavior is decided by capability, never by comparing versions.
public nonisolated struct ServerHandshake: Sendable, Equatable {
    /// Which server answered.
    public var kind: ServerKind
    /// Where it runs.
    public var host: ServerHost
    /// The server's build (a commit), nil when it does not say.
    public var build: String?
    /// The wire protocol version, nil when the server does not report one (acpmux today).
    public var protocolVersion: Int?
    /// The capabilities it advertises; nil when it advertises none (acpmux today), so only a
    /// build difference can tell it is older.
    public var capabilities: Set<String>?
    /// Whether a restart keeps the server's running work: cmux-tui keeps every terminal; acpmux
    /// keeps its agents only when it runs them under agent hosts.
    public var keepsWorkAcrossRestart: Bool
    /// The server's release version for display ("0.67.0"), nil when it does not say. Display
    /// only: behavior never compares versions.
    public var version: String?

    /// - Parameters:
    ///   - kind: Which server answered.
    ///   - host: Where it runs.
    ///   - build: Its build commit, if known.
    ///   - protocolVersion: Its protocol version, if reported.
    ///   - capabilities: The advertised capabilities, or nil when it advertises none.
    ///   - keepsWorkAcrossRestart: Whether a restart keeps running work (default true).
    ///   - version: Its release version for display, if reported.
    public init(kind: ServerKind, host: ServerHost, build: String?, protocolVersion: Int?,
                capabilities: Set<String>?, keepsWorkAcrossRestart: Bool = true, version: String? = nil) {
        self.kind = kind
        self.host = host
        self.build = build
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.keepsWorkAcrossRestart = keepsWorkAcrossRestart
        self.version = version
    }
}
