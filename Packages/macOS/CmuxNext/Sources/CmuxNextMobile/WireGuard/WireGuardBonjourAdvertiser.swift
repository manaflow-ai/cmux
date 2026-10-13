public import Foundation

/// Advertises the WireGuard phone host on the local network
/// (`_cmux-wg._udp`, TXT `id=<host id>`), so a paired phone whose saved
/// addresses went stale (a new DHCP lease, another Wi-Fi) can find this Mac
/// again. It reveals only that a cmux Mac is here and its host id; the
/// tunnel still needs the phone's paired key.
@MainActor
public final class WireGuardBonjourAdvertiser {
    public static let serviceType = "_cmux-wg._udp."
    private var service: NetService?
    private var published: (port: UInt16, hostID: String)?

    public init() {}

    /// Publishes (or republishes after a change) the advertisement.
    public func publish(name: String, hostID: String, port: UInt16) {
        guard published.map({ $0.port != port || $0.hostID != hostID }) ?? true else { return }
        stop()
        let service = NetService(domain: "local.", type: Self.serviceType, name: name, port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: ["id": Data(hostID.utf8)]))
        service.publish()
        self.service = service
        published = (port, hostID)
    }

    public func stop() {
        service?.stop()
        service = nil
        published = nil
    }
}
