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
    /// The record came from another machine's tree.
    case remoteRecord
    /// The tab's address is not a valid remote view record.
    case invalidAddress
}
