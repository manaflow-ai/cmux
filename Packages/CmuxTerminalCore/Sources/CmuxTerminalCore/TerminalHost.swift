public import CmuxMobileContract
public import Foundation

/// A configured terminal host (a remote machine cmux can open terminal workspaces on).
///
/// A host carries its connection identity (hostname, port, username), transport preference,
/// SSH authentication method, optional WebSocket/daemon endpoint, and the latest known
/// ``MobileMachineStatus`` reported by mobile sync.
public struct TerminalHost: Identifiable, Codable, Equatable, Sendable {
    /// The stable identity type for a host.
    public typealias ID = UUID

    /// The locally-unique identifier for this host record.
    public let id: ID
    /// A stable, cross-device identifier derived from the host's identity (defaults to ``id``).
    public var stableID: String
    /// The user-visible display name.
    public var name: String
    /// The SSH hostname or IP address.
    public var hostname: String
    /// The SSH port.
    public var port: Int
    /// The SSH username.
    public var username: String
    /// The SF Symbol name used to represent the host.
    public var symbolName: String
    /// The accent palette used to color the host.
    public var palette: TerminalHostPalette
    /// The command run to bootstrap a session (defaults to a tmux attach-or-create).
    public var bootstrapCommand: String
    /// The host key the user has trusted, if any.
    public var trustedHostKey: String?
    /// A host key awaiting trust confirmation, if any.
    public var pendingHostKey: String?
    /// The sort position of the host in the sidebar.
    public var sortIndex: Int
    /// Whether the host was discovered or user-created.
    public var source: TerminalHostSource
    /// The preferred transport used to reach the host.
    public var transportPreference: TerminalTransportPreference
    /// The SSH authentication method to use.
    public var sshAuthenticationMethod: TerminalSSHAuthenticationMethod
    /// The team identifier this host is scoped to, if any.
    public var teamID: String?
    /// The backend server identifier for this host, if any.
    public var serverID: String?
    /// Whether SSH fallback is permitted when a direct/daemon transport fails.
    public var allowsSSHFallback: Bool
    /// The direct-TLS certificate pins trusted for this host.
    public var directTLSPins: [String]
    /// The WebSocket port for the cmuxd-remote endpoint, if any.
    public var wsPort: Int?
    /// The WebSocket secret for the cmuxd-remote endpoint, if any.
    public var wsSecret: String?
    /// The latest reachability status reported by mobile sync, if any.
    public var machineStatus: MobileMachineStatus?
    /// The latest workspace change sequence observed from the daemon, if any.
    public var daemonWorkspaceChangeSeq: UInt64?

    /// Creates a terminal host.
    ///
    /// - Parameters:
    ///   - id: The local identifier (defaults to a fresh UUID).
    ///   - stableID: The stable cross-device identifier (defaults to `id.uuidString`).
    ///   - name: The display name.
    ///   - hostname: The SSH hostname or IP.
    ///   - port: The SSH port (defaults to `22`).
    ///   - username: The SSH username.
    ///   - symbolName: The SF Symbol name.
    ///   - palette: The accent palette.
    ///   - bootstrapCommand: The session bootstrap command.
    ///   - trustedHostKey: The trusted host key, if any.
    ///   - pendingHostKey: A host key awaiting trust, if any.
    ///   - sortIndex: The sidebar sort position.
    ///   - source: Whether discovered or custom (defaults to `.custom`).
    ///   - transportPreference: The preferred transport (defaults to `.rawSSH`).
    ///   - sshAuthenticationMethod: The SSH auth method (defaults to `.password`).
    ///   - teamID: The team scope, if any.
    ///   - serverID: The backend server id, if any.
    ///   - allowsSSHFallback: Whether SSH fallback is permitted (defaults to `true`).
    ///   - directTLSPins: The direct-TLS pins (normalized on assignment).
    ///   - wsPort: The WebSocket port, if any.
    ///   - wsSecret: The WebSocket secret, if any.
    ///   - machineStatus: The latest mobile-sync status, if any.
    ///   - daemonWorkspaceChangeSeq: The latest daemon workspace change sequence, if any.
    public init(
        id: ID = UUID(),
        stableID: String? = nil,
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        symbolName: String,
        palette: TerminalHostPalette,
        bootstrapCommand: String = "tmux new-session -A -s {{session}}",
        trustedHostKey: String? = nil,
        pendingHostKey: String? = nil,
        sortIndex: Int = 0,
        source: TerminalHostSource = .custom,
        transportPreference: TerminalTransportPreference = .rawSSH,
        sshAuthenticationMethod: TerminalSSHAuthenticationMethod = .password,
        teamID: String? = nil,
        serverID: String? = nil,
        allowsSSHFallback: Bool = true,
        directTLSPins: [String] = [],
        wsPort: Int? = nil,
        wsSecret: String? = nil,
        machineStatus: MobileMachineStatus? = nil,
        daemonWorkspaceChangeSeq: UInt64? = nil
    ) {
        self.id = id
        self.stableID = stableID ?? id.uuidString
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.symbolName = symbolName
        self.palette = palette
        self.bootstrapCommand = bootstrapCommand
        self.trustedHostKey = trustedHostKey
        self.pendingHostKey = pendingHostKey
        self.sortIndex = sortIndex
        self.source = source
        self.transportPreference = transportPreference
        self.sshAuthenticationMethod = sshAuthenticationMethod
        self.teamID = teamID
        self.serverID = serverID
        self.allowsSSHFallback = allowsSSHFallback
        self.directTLSPins = directTLSPins.normalizedTerminalPins
        self.wsPort = wsPort
        self.wsSecret = wsSecret
        self.machineStatus = machineStatus
        self.daemonWorkspaceChangeSeq = daemonWorkspaceChangeSeq
    }

    /// Whether the host exposes a usable WebSocket (cmuxd-remote) endpoint.
    public var hasWebSocketEndpoint: Bool {
        wsPort != nil && !(wsSecret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// A user-visible `username@hostname` subtitle, or an SSH-setup-required prompt when unconfigured.
    public var subtitle: String {
        guard !hostname.isEmpty, !username.isEmpty else {
            return String(
                localized: "terminal.host.setup_required",
                defaultValue: "SSH setup required"
            )
        }
        return "\(username)@\(hostname)"
    }

    /// Whether the host has the minimum configuration (hostname and username) to connect.
    public var isConfigured: Bool {
        !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A slugified form of the host name suitable for accessibility labels.
    public var accessibilitySlug: String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// A slugified form of the stable identifier suitable for accessibility identifiers.
    public var accessibilityIdentifierSlug: String {
        stableID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    /// The backend server identifier, falling back to ``stableID`` when none is set.
    public var effectiveServerID: String {
        serverID ?? stableID
    }

    /// Whether the host is scoped to a non-empty team identifier (a direct-daemon team scope).
    public var hasDirectDaemonTeamScope: Bool {
        !(teamID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Whether a saved SSH password is required to connect with the current settings.
    public var requiresSavedSSHPassword: Bool {
        if hasWebSocketEndpoint { return false }
        return switch transportPreference {
        case .rawSSH:
            sshAuthenticationMethod == .password
        case .remoteDaemon:
            !hasDirectDaemonTeamScope && sshAuthenticationMethod == .password
        }
    }

    /// Whether a saved SSH private key is required to connect with the current settings.
    public var requiresSavedSSHPrivateKey: Bool {
        if hasWebSocketEndpoint { return false }
        return switch transportPreference {
        case .rawSSH:
            sshAuthenticationMethod == .privateKey
        case .remoteDaemon:
            !hasDirectDaemonTeamScope && sshAuthenticationMethod == .privateKey
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case stableID
        case name
        case hostname
        case port
        case username
        case symbolName
        case palette
        case bootstrapCommand
        case trustedHostKey
        case pendingHostKey
        case sortIndex
        case source
        case transportPreference
        case sshAuthenticationMethod
        case teamID
        case serverID
        case allowsSSHFallback
        case directTLSPins
        case wsPort
        case wsSecret
        case machineStatus
        case daemonWorkspaceChangeSeq
    }

    /// Decodes a host, backfilling a legacy stable identifier and defaults for newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ID.self, forKey: .id)
        let hostname = try container.decode(String.self, forKey: .hostname)
        let source = try container.decodeIfPresent(TerminalHostSource.self, forKey: .source) ?? .custom
        self.init(
            id: id,
            stableID: try container.decodeIfPresent(String.self, forKey: .stableID) ?? Self.legacyStableID(
                hostname: hostname,
                fallbackID: id
            ),
            name: try container.decode(String.self, forKey: .name),
            hostname: hostname,
            port: try container.decode(Int.self, forKey: .port),
            username: try container.decode(String.self, forKey: .username),
            symbolName: try container.decode(String.self, forKey: .symbolName),
            palette: try container.decode(TerminalHostPalette.self, forKey: .palette),
            bootstrapCommand: try container.decode(String.self, forKey: .bootstrapCommand),
            trustedHostKey: try container.decodeIfPresent(String.self, forKey: .trustedHostKey),
            pendingHostKey: try container.decodeIfPresent(String.self, forKey: .pendingHostKey),
            sortIndex: try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0,
            source: source,
            transportPreference: try container.decodeIfPresent(TerminalTransportPreference.self, forKey: .transportPreference) ?? .rawSSH,
            sshAuthenticationMethod: try container.decodeIfPresent(
                TerminalSSHAuthenticationMethod.self,
                forKey: .sshAuthenticationMethod
            ) ?? .password,
            teamID: try container.decodeIfPresent(String.self, forKey: .teamID),
            serverID: try container.decodeIfPresent(String.self, forKey: .serverID),
            allowsSSHFallback: try container.decodeIfPresent(Bool.self, forKey: .allowsSSHFallback) ?? true,
            directTLSPins: try container.decodeIfPresent([String].self, forKey: .directTLSPins) ?? [],
            wsPort: try container.decodeIfPresent(Int.self, forKey: .wsPort),
            wsSecret: try container.decodeIfPresent(String.self, forKey: .wsSecret),
            machineStatus: try container.decodeIfPresent(MobileMachineStatus.self, forKey: .machineStatus),
            daemonWorkspaceChangeSeq: try container.decodeIfPresent(UInt64.self, forKey: .daemonWorkspaceChangeSeq)
        )
    }

    private static func legacyStableID(hostname: String, fallbackID: ID) -> String {
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHostname.isEmpty {
            return trimmedHostname.lowercased()
        }
        return fallbackID.uuidString
    }
}
