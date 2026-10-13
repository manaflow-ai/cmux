public import Foundation

/// Advertises the WireGuard phone host on the local network
/// (`_cmux-wg._udp`, TXT `id=<host id>`), so a paired phone whose saved
/// addresses went stale (a new DHCP lease, another Wi-Fi) can find this Mac
/// again. It reveals only that a cmux Mac is here and its host id; the
/// tunnel still needs the phone's paired key, or the current pairing code.
@MainActor
public final class WireGuardBonjourAdvertiser {
    public static let serviceType = "_cmux-wg._udp."
    private var service: NetService?
    private var published: (port: UInt16, hostID: String, hostKey: String)?

    public init() {}

    /// Publishes (or republishes after a change) the advertisement.
    public func publish(name: String, hostID: String, hostKey: String, port: UInt16) {
        guard published.map({ $0.port != port || $0.hostID != hostID || $0.hostKey != hostKey }) ?? true else { return }
        stop()
        let service = NetService(domain: "local.", type: Self.serviceType, name: name, port: Int32(truncatingIfNeeded: port))
        // `hk` lets a phone that has only the typed code rebuild the invitation.
        service.setTXTRecord(NetService.data(fromTXTRecord: ["id": Data(hostID.utf8), "hk": Data(hostKey.utf8), "v": Data("1".utf8)]))
        service.publish()
        self.service = service
        published = (port, hostID, hostKey)
    }

    public func stop() {
        service?.stop()
        service = nil
        published = nil
    }
}
