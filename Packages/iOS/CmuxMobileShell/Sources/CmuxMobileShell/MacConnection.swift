import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// One paired Mac's focused connection in the multi-Mac connection pool.
///
/// The composite holds one entry per connected Mac, keyed by `macDeviceID`.
/// The focused entry drives terminal I/O and render traffic. Control entries use
/// ``SecondaryMacSubscription`` and remain warm without terminal render topics.
struct MacConnection {
    /// The stable device id of the Mac this connection targets.
    let macDeviceID: String
    /// The attach ticket the connection was established with.
    let ticket: CmxAttachTicket
    /// The route (host/port + kind) the client dialed.
    let route: CmxAttachRoute
    /// The live RPC client for this Mac.
    let client: MobileCoreRPCClient
    /// The connection-attempt generation that established this client.
    let generation: UUID
    /// Human-readable name shown in per-Mac connection diagnostics.
    let displayName: String?
    /// Authenticated or stored app-instance authority for this session.
    let instanceTag: String?
    /// Host capabilities retained so a focused session can become control-only.
    let supportedHostCapabilities: Set<String>
    /// Workspace command capabilities retained across role changes.
    let actionCapabilities: MobileWorkspaceActionCapabilities
}
