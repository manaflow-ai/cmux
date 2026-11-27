import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One paired Mac session's focused-terminal capability.
///
/// The composite holds one entry per connected Mac, keyed by `macDeviceID`.
/// Focus drives terminal I/O and render traffic. The same live RPC client may
/// retain ``SecondaryMacSubscription`` control work throughout focus changes.
struct MacConnection {
    /// The stable device id of the Mac this connection targets.
    let macDeviceID: String
    /// The typed pool identity: canonical device + STORED tag, matching the
    /// control-subscription keying so promotion/demotion round-trips one key.
    var ownerKey: MacPairingKey {
        MacPairingKey(macDeviceID: macDeviceID, instanceTag: storedInstanceTag)
    }
    /// The attach ticket the connection was established with.
    let ticket: CmxAttachTicket
    /// The route (host/port + kind) the client dialed.
    let route: CmxAttachRoute
    /// The live RPC client for this Mac.
    let client: MobileCoreRPCClient
    /// The live generation published when this client took focus.
    let generation: UUID
    /// Human-readable name shown in per-Mac connection diagnostics.
    let displayName: String?
    /// Authority retained by the paired row when this session was established.
    let storedInstanceTag: String?
    /// App-instance identity proven by this live session.
    let authenticatedInstanceTag: String?
    /// The best live identity for diagnostics and connection snapshots.
    var instanceTag: String? {
        authenticatedInstanceTag ?? storedInstanceTag
    }
    /// Host capabilities retained so a focused session can become control-only.
    let supportedHostCapabilities: Set<String>
    /// Workspace command capabilities retained across role changes.
    let actionCapabilities: MobileWorkspaceActionCapabilities

    init(
        macDeviceID: String,
        ticket: CmxAttachTicket,
        route: CmxAttachRoute,
        client: MobileCoreRPCClient,
        generation: UUID,
        displayName: String?,
        storedInstanceTag: String?,
        authenticatedInstanceTag: String?,
        supportedHostCapabilities: Set<String>,
        actionCapabilities: MobileWorkspaceActionCapabilities
    ) {
        self.macDeviceID = macDeviceID
        self.ticket = ticket
        self.route = route
        self.client = client
        self.generation = generation
        self.displayName = displayName
        self.storedInstanceTag = storedInstanceTag
        self.authenticatedInstanceTag = authenticatedInstanceTag
        self.supportedHostCapabilities = supportedHostCapabilities
        self.actionCapabilities = actionCapabilities
    }

    /// Convenience for callers whose stored and authenticated authorities are
    /// intentionally identical.
    init(
        macDeviceID: String,
        ticket: CmxAttachTicket,
        route: CmxAttachRoute,
        client: MobileCoreRPCClient,
        generation: UUID,
        displayName: String?,
        instanceTag: String?,
        supportedHostCapabilities: Set<String>,
        actionCapabilities: MobileWorkspaceActionCapabilities
    ) {
        self.init(
            macDeviceID: macDeviceID,
            ticket: ticket,
            route: route,
            client: client,
            generation: generation,
            displayName: displayName,
            storedInstanceTag: instanceTag,
            authenticatedInstanceTag: instanceTag,
            supportedHostCapabilities: supportedHostCapabilities,
            actionCapabilities: actionCapabilities
        )
    }
}
