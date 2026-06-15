import Foundation

/// Everything needed to establish and operate one remote-workspace connection:
/// transport selection, SSH identity/options, relay and proxy wiring, and the
/// persistent-PTY restore knobs.
///
/// This is a pure `Sendable` value; all normalization helpers are pure string
/// transforms (see `WorkspaceRemoteConfiguration+SSHOptionNormalization.swift`).
public struct WorkspaceRemoteConfiguration: Equatable, Sendable {
    /// Transport used to reach the host.
    public let transport: WorkspaceRemoteTransport
    /// SSH destination (`user@host` or `host`).
    public let destination: String
    /// Explicit SSH port, when configured.
    public let port: Int?
    /// Explicit identity file path, when configured.
    public let identityFile: String?
    /// `-o` SSH options applied to every spawned SSH process.
    public let sshOptions: [String]
    /// Deterministic local proxy port override (docker regression test hook).
    public let localProxyPort: Int?
    /// CLI relay port for remote `cmux` command forwarding.
    public let relayPort: Int?
    /// Relay identity advertised to the remote CLI.
    public let relayID: String?
    /// Shared secret authenticating relay clients.
    public let relayToken: String?
    /// Local control-socket path forwarded over the relay.
    public let localSocketPath: String?
    /// Startup command run in new terminal surfaces for this workspace.
    public let terminalStartupCommand: String?
    /// One-shot token gating auto-connect on foreground SSH authentication.
    public let foregroundAuthToken: String?
    /// SSH agent socket injected as `SSH_AUTH_SOCK`, when usable.
    public let agentSocketPath: String?
    /// Brokered WebSocket daemon endpoint for Cloud VM transports.
    public let daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint?
    /// Whether remote PTY sessions outlive their local terminal surface.
    public let preserveAfterTerminalExit: Bool
    /// Slot name isolating persistent daemons per workspace identity.
    public let persistentDaemonSlot: String?
    /// True for cloud-VM remotes (Freestyle snapshots) where cmuxd-remote is pre-baked in
    /// the image and started via systemd. Skip the upload+exec bootstrap entirely and synthesize
    /// a `DaemonHello`. Reverse-relay still stays off, but SSH-backed VM workspaces can talk to
    /// the baked daemon through an SSH local forward to `/run/cmuxd-remote.sock`.
    public let skipDaemonBootstrap: Bool
    /// Desktop-to-desktop mobile attach metadata carried by an SSH local forward.
    public let remoteMacTunnel: WorkspaceRemoteMacTunnel?

    /// Creates a configuration, normalizing the agent socket path and gating
    /// the persistent daemon slot on `preserveAfterTerminalExit` exactly like
    /// the original app-target initializer.
    public init(
        transport: WorkspaceRemoteTransport = .ssh,
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        localProxyPort: Int?,
        relayPort: Int?,
        relayID: String?,
        relayToken: String?,
        localSocketPath: String?,
        terminalStartupCommand: String?,
        foregroundAuthToken: String? = nil,
        agentSocketPath: String? = nil,
        daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint? = nil,
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil,
        skipDaemonBootstrap: Bool = false,
        remoteMacTunnel: WorkspaceRemoteMacTunnel? = nil
    ) {
        self.transport = transport
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.localProxyPort = localProxyPort
        self.relayPort = relayPort
        self.relayID = relayID
        self.relayToken = relayToken
        self.localSocketPath = localSocketPath
        self.terminalStartupCommand = terminalStartupCommand
        self.foregroundAuthToken = foregroundAuthToken
        self.agentSocketPath = Self.normalizedAgentSocketPath(agentSocketPath)
        self.daemonWebSocketEndpoint = daemonWebSocketEndpoint
        self.preserveAfterTerminalExit = preserveAfterTerminalExit
        self.persistentDaemonSlot = preserveAfterTerminalExit
            ? Self.normalizedPersistentDaemonSlot(persistentDaemonSlot)
            : nil
        self.skipDaemonBootstrap = skipDaemonBootstrap
        self.remoteMacTunnel = remoteMacTunnel
    }

    /// Resolves the SSH agent socket to use for a remote configuration from an explicit socket or durable options.
    public static func resolvedAgentSocketPath(
        sshOptions: [String],
        explicitAgentSocketPath: String? = nil,
        explicitAgentSocketPathIsSet: Bool = false
    ) -> String? {
        if explicitAgentSocketPathIsSet {
            return existingAgentSocketPath(explicitAgentSocketPath)
        }
        return existingAgentSocketPath(explicitAgentSocketPath)
            ?? existingAgentSocketPath(sshAgentSocketPath(for: sshOptions))
    }

    /// `destination` or `destination:port` for user-facing status text.
    public var displayTarget: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }

    /// The stable key the proxy broker uses to share one daemon tunnel across
    /// workspaces that target the same transport identity.
    public var proxyBrokerTransportKey: String {
        let normalizedTransport = transport.rawValue
        let normalizedBootstrapMode = skipDaemonBootstrap ? "vm-baked" : "bootstrap"
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.map(String.init) ?? ""
        let normalizedIdentity = Self.normalizedIdentityPath(identityFile) ?? ""
        let normalizedLocalProxyPort = localProxyPort.map(String.init) ?? ""
        let normalizedOptions = Self.proxyBrokerSSHOptions(sshOptions).joined(separator: "\u{1f}")
        let normalizedWebSocketDaemon = daemonWebSocketEndpoint?.proxyBrokerKeyComponent ?? ""
        let normalizedRequiredCapabilities = preserveAfterTerminalExit ? "pty.session" : ""
        let normalizedPersistentDaemonSlot = persistentDaemonSlot ?? ""
        return [
            normalizedTransport,
            normalizedBootstrapMode,
            normalizedDestination,
            normalizedPort,
            normalizedIdentity,
            normalizedOptions,
            normalizedLocalProxyPort,
            normalizedWebSocketDaemon,
            normalizedRequiredCapabilities,
            normalizedPersistentDaemonSlot,
        ]
            .joined(separator: "\u{1e}")
    }

    private static func proxyBrokerSSHOptions(_ options: [String]) -> [String] {
        durableSSHOptions(options)
    }

    /// True when `other` addresses the same persistent-PTY daemon identity, so
    /// reconfiguration can keep existing persistent sessions alive.
    public func hasSamePersistentPTYIdentity(as other: WorkspaceRemoteConfiguration) -> Bool {
        guard preserveAfterTerminalExit,
              other.preserveAfterTerminalExit,
              let persistentDaemonSlot,
              persistentDaemonSlot == other.persistentDaemonSlot else {
            return false
        }

        return transport == other.transport
            && skipDaemonBootstrap == other.skipDaemonBootstrap
            && destination.trimmingCharacters(in: .whitespacesAndNewlines)
                == other.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            && port == other.port
            && relayPort == other.relayPort
            && Self.normalizedIdentityPath(identityFile)
                == Self.normalizedIdentityPath(other.identityFile)
            && Self.proxyBrokerSSHOptions(sshOptions) == Self.proxyBrokerSSHOptions(other.sshOptions)
            && daemonWebSocketEndpoint?.proxyBrokerKeyComponent == other.daemonWebSocketEndpoint?.proxyBrokerKeyComponent
    }
}

extension WorkspaceRemoteConfiguration {
    /// Environment injected into remote terminal startup commands
    /// (`SSH_AUTH_SOCK` only), or `nil` when no agent socket is configured.
    public var sshTerminalStartupEnvironment: [String: String]? {
        guard let agentSocketPath = self.agentSocketPath else {
            return nil
        }
        return ["SSH_AUTH_SOCK": agentSocketPath]
    }

    /// Full process environment for spawned ssh/scp processes with
    /// `SSH_AUTH_SOCK` overridden, or `nil` when no agent socket is configured.
    public var sshProcessEnvironment: [String: String]? {
        guard let agentSocketPath = self.agentSocketPath else {
            return nil
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = agentSocketPath
        return environment
    }

    /// SSH options propagated to a forked agent workspace (durable subset).
    public static func forkedAgentSSHOptions(_ options: [String]) -> [String] {
        forkedWorkspaceSSHOptions(options)
    }

    /// The durable snapshot persisted into session state, or `nil` for
    /// non-SSH transports or an empty destination.
    public func sessionSnapshot(sshOptionsOverride: [String]? = nil) -> SessionRemoteWorkspaceSnapshot? {
        guard transport == .ssh else { return nil }
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDestination.isEmpty else { return nil }

        return SessionRemoteWorkspaceSnapshot(
            transport: transport,
            destination: normalizedDestination,
            port: port,
            identityFile: Self.normalizedIdentityPath(identityFile),
            sshOptions: sshOptionsOverride ?? Self.durableSSHOptions(sshOptions),
            preserveAfterTerminalExit: preserveAfterTerminalExit ? true : nil,
            skipDaemonBootstrap: skipDaemonBootstrap,
            relayPort: preserveAfterTerminalExit ? relayPort : nil,
            persistentDaemonSlot: preserveAfterTerminalExit ? persistentDaemonSlot : nil,
            remoteMacTunnel: remoteMacTunnel
        )
    }
}

public struct WorkspaceRemoteMacTunnel: Codable, Equatable, Sendable {
    public let localHost: String
    public let localPort: Int
    public let remoteHost: String
    public let remotePort: Int
    /// Remote cmux window UUID this local window mirrors, when known.
    public let remoteWindowID: String?

    public init?(
        localHost: String?,
        localPort: Int?,
        remoteHost: String?,
        remotePort: Int?,
        remoteWindowID: String? = nil
    ) {
        guard let localHost = Self.normalizedHost(localHost),
              let localPort,
              (1...65535).contains(localPort),
              let remoteHost = Self.normalizedHost(remoteHost),
              let remotePort,
              (1...65535).contains(remotePort) else {
            return nil
        }
        self.localHost = localHost
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.remoteWindowID = Self.normalizedWindowID(remoteWindowID)
    }

    public init?(
        localEndpoint: String?,
        forwardTarget: String?,
        remoteWindowID: String? = nil
    ) {
        let local = Self.splitHostPort(localEndpoint)
        let remote = Self.splitHostPort(forwardTarget)
        self.init(
            localHost: local?.host,
            localPort: local?.port,
            remoteHost: remote?.host,
            remotePort: remote?.port,
            remoteWindowID: remoteWindowID
        )
    }

    public var localEndpoint: String {
        "\(localHost):\(localPort)"
    }

    public var forwardTarget: String {
        "\(remoteHost):\(remotePort)"
    }

    public var localForwardSSHOption: String {
        "LocalForward=\(localEndpoint) \(forwardTarget)"
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedHost(_ value: String?) -> String? {
        guard let host = normalizedString(value),
              !host.contains(" "),
              !host.contains("\t"),
              !host.contains("\n") else {
            return nil
        }
        return host
    }

    private static func normalizedWindowID(_ value: String?) -> String? {
        guard let value = normalizedString(value),
              UUID(uuidString: value) != nil else {
            return nil
        }
        return value.uppercased()
    }

    private static func splitHostPort(_ value: String?) -> (host: String, port: Int)? {
        guard let value = normalizedString(value),
              let separator = value.lastIndex(of: ":") else {
            return nil
        }
        let host = String(value[..<separator])
        let portText = String(value[value.index(after: separator)...])
        guard let port = Int(portText) else { return nil }
        return (host, port)
    }
}
