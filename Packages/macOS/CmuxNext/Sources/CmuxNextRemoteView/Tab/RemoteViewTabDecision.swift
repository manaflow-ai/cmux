import Foundation

/// Where a `remote_view` tab record came from, as the App knows it.
public nonisolated enum RemoteViewTabSource: Sendable, Hashable {
    /// A record in a remote machine's tree. Never opens (the App already
    /// opens only web pages from remote records, `RemoteRelayPolicy`).
    case remoteTree
    /// A local record nobody confirmed in this process: created by the CLI,
    /// MCP, a script or an agent, or restored after a relaunch.
    case unconfirmed
    /// A local record a person opened in this app (address bar, a menu, or
    /// the Connect button of an unconfirmed tab).
    case person
}

/// Human-facing context shared by remote connection gates. Machine ids stay in the transport
/// record; the gate receives only the name and status a person needs.
public nonisolated struct RemoteConnectionTarget: Sendable, Hashable {
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case desktop, terminal, browser, ports

        var noun: String {
            switch self {
            case .desktop: "desktop"
            case .terminal: "terminal"
            case .browser: "browser"
            case .ports: "port preview"
            }
        }
    }

    public var name: String
    public var status: String?
    public var region: String?
    public var kind: Kind
    /// Script, agent and restore opens require an explicit press. Person-opened targets skip the gate.
    public var requiresConfirmation: Bool

    public init(name: String, status: String? = nil, region: String? = nil, kind: Kind = .desktop,
                requiresConfirmation: Bool = true) {
        self.name = name
        self.status = status
        self.region = region
        self.kind = kind
        self.requiresConfirmation = requiresConfirmation
    }
}

/// What a `remote_view` tab shows.
public nonisolated enum RemoteViewTabDecision: Sendable, Hashable {
    /// Start the pane for the record (the App picks the stream source).
    case connect(RemoteViewTabRecord)
    /// Ask the person before any session starts: Connect, or leave it.
    case confirm(RemoteViewTabRecord)
    /// Show why there is no desktop.
    case unavailable(RemoteViewUnavailableReason)
}

/// Why a `remote_view` tab shows no desktop.
public nonisolated enum RemoteViewUnavailableReason: Sendable, Hashable {
    /// This build has no remote desktop pane (`RemoteViewAvailability`).
    case notInThisBuild
    /// The pane exists but this build cannot connect to `host` yet.
    case noTransport(host: String)
    /// Phase 1 connects only to this machine (plan 11.0).
    case notLoopback(host: String)
    /// A VNC host outside this Mac, the tailnet and the local network
    /// (VNC sessions are not encrypted; section 12).
    case notPrivateNetwork(host: String)
    /// The record came from another machine's tree.
    case remoteRecord
    /// The tab's address is not a valid remote view record.
    case invalidAddress
}
