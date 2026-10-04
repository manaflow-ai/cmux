import Foundation

/// How a `DaemonConnection` connects, reconnects and bounds its requests.
public struct DaemonConnectionConfiguration: Sendable {
    public var clientName: String
    public var requiredCapabilities: [String]
    public var advertisedCapabilities: [String]
    public var treeEvents: TreeEventMode
    /// Spacing and budget of reconnect attempts.
    public var retry: RetryPolicy
    /// A connection that stays up this long resets the reconnect backoff.
    public var healthyAfter: Duration
    /// Extra events that may let a reconnect succeed (network, sign-in).
    /// The connection also watches its daemon socket through it.
    public var retryWake: RetryWake?
    /// Deadline for every control-plane request (architecture.md 5a).
    /// A miss throws `DaemonError.timedOut`; nil disables it (tests only).
    public var requestTimeout: Duration?
    /// Deadline for `list-workspaces` snapshots, which can be large.
    public var snapshotTimeout: Duration?
    /// Deadline for commands that launch a terminal host
    /// (`TerminalSpawningRequest`): cmux-tui's own 3 s launch bound plus margin.
    public var spawnTimeout: Duration?
    /// Per-terminal `env` the convenience spawn calls send when the daemon
    /// supports `terminal-env-v1` and the caller passed none. Nil sends none.
    public var terminalEnvironment: (@Sendable () async -> [String: String])?
    /// True when `terminalEnvironment` carries Ghostty's shell integration
    /// resolved from the user's Ghostty config (the local daemon's
    /// `AppEnvironment.terminalEnvironmentProvider`). The connection then
    /// echoes `terminal-frontend-shell-integration-v1`, so the daemon does
    /// not integrate the shell a second time.
    public var resolvesShellIntegration: Bool
    /// Opens `session.events` after each connect for the daemon's state
    /// resources (`DaemonStore.session`); off sends nothing extra.
    public var sessionEvents: Bool
    /// The connection's role. `page_relay` sends `client-hello {role: page_relay}` after
    /// `identify`, no `set-client-info` label and no `subscribe`, and refuses a daemon without
    /// `origin-claim-v1`: its requests must never run with a client role. `main` sends no hello
    /// until P8 (request-origin.md).
    public var role: DaemonClientRole
    /// Where a page relay connection stores its `client-hello` id; nil otherwise.
    public var relayIdentity: PageRelayIdentity?

    public init(
        clientName: String = "cmux-next",
        requiredCapabilities: [String] = DaemonCapabilities.shared.required,
        advertisedCapabilities: [String] = DaemonCapabilities.shared.advertised,
        treeEvents: TreeEventMode = .deltas,
        retry: RetryPolicy = .reconnect,
        healthyAfter: Duration = .seconds(10),
        retryWake: RetryWake? = nil,
        requestTimeout: Duration? = DaemonConnection.defaultRequestTimeout,
        snapshotTimeout: Duration? = .seconds(10),
        spawnTimeout: Duration? = DaemonConnection.defaultSpawnTimeout,
        terminalEnvironment: (@Sendable () async -> [String: String])? = TerminalEnvironment.instance.shared(),
        resolvesShellIntegration: Bool = false,
        sessionEvents: Bool = false,
        role: DaemonClientRole = .main,
        relayIdentity: PageRelayIdentity? = nil
    ) {
        self.clientName = clientName
        self.requiredCapabilities = requiredCapabilities
        self.advertisedCapabilities = advertisedCapabilities
        self.treeEvents = treeEvents
        self.retry = retry
        self.healthyAfter = healthyAfter
        self.retryWake = retryWake
        self.requestTimeout = requestTimeout
        self.snapshotTimeout = snapshotTimeout
        self.spawnTimeout = requestTimeout == nil ? nil : spawnTimeout
        self.terminalEnvironment = terminalEnvironment
        self.resolvesShellIntegration = resolvesShellIntegration && terminalEnvironment != nil
        self.sessionEvents = sessionEvents
        self.role = role
        self.relayIdentity = relayIdentity
    }
}

extension DaemonConnectionConfiguration {
    /// What the connection echoes in `set-client-info`.
    var handshakeCapabilities: [String] {
        DaemonCapabilities.shared.handshakeCapabilities(advertisedCapabilities,
                                                        resolvesShellIntegration: resolvesShellIntegration)
    }
}
