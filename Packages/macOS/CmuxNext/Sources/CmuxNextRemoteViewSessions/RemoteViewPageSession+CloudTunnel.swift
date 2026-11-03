public import CmuxNextRemoteLocalhost
import Foundation

extension RemoteViewPageSession {
    /// Open Desktop's native viewer: a Cloud machine's websockify port (6901, next to its noVNC)
    /// over this Mac's own Cloud tunnel (`hub`, to the machine's private `address`), with the hub's
    /// client token; no port opens on this Mac. Nil when the tunnel cannot reach it (signed out,
    /// the machine without an address). Open Desktop's page and the Chief Settings card's Computer
    /// section (cmux issue 31488) both stream through it.
    public static func cloudDesktopTransport(hub: HubLoopbackOpener.Hub?, address: String?)
        -> (@Sendable () async throws -> CloudDesktopStream)? {
        guard let hub, let address, let opener = HubLoopbackOpener(hub: hub, address: address) else { return nil }
        return {
            let tunnel = try await opener.openTunnel(host: "localhost", port: 6901)
            let reader = LoopbackTunnelReader(tunnel)
            return CloudDesktopStream(read: { try await reader.read() }, write: { try await tunnel.write($0) },
                                      close: { tunnel.close() })
        }
    }
}
