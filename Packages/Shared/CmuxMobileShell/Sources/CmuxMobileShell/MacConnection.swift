import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// One paired Mac's live connection in the multi-Mac connection pool (P2).
///
/// The composite holds one entry per connected Mac, keyed by `macDeviceID`.
/// Today the pool tracks the single foreground connection that drives terminal
/// I/O and the connected UI; P3 adds read-only connections to the user's other
/// Macs so their workspaces can be fetched and merged into one list. Keeping
/// each connection's `generation` lets a per-Mac connection be invalidated
/// independently of the others, instead of the single global generation that
/// cancels everything on any attach.
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
}
