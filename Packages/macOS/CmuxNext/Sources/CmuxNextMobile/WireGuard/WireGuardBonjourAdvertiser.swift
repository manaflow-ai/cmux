public import Foundation
import dnssd
import os

/// Advertises the WireGuard phone host on the local network
/// (`_cmux-wg._udp`, TXT `id=<host id>`, `hk=<public key>`), so a paired
/// phone whose saved addresses went stale (a new DHCP lease, another Wi-Fi)
/// can find this Mac again, and a phone holding a typed pairing code can
/// rebuild its invitation. It reveals only that a cmux Mac is here, its host
/// id and public key; the tunnel still needs a paired key or the current code.
///
/// Registered through dns_sd: the WireGuard socket belongs to libcmuxwg, so
/// the record names that port without binding anything here.
@MainActor
public final class WireGuardBonjourAdvertiser {
    public static let serviceType = "_cmux-wg._udp"
    private var registration: DNSServiceRef?
    /// nil while not advertising, 0 when registered, else the dns_sd error.
    public private(set) var status: Int32?
    private var published: (port: UInt16, hostID: String, hostKey: String)?
    private let queue = DispatchQueue(label: "cmux.next.mobile.bonjour")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.wireguard")

    public init() {}

    /// Publishes (or republishes after a change) the advertisement.
    public func publish(name: String, hostID: String, hostKey: String, port: UInt16) {
        guard published.map({ $0.port != port || $0.hostID != hostID || $0.hostKey != hostKey }) ?? true else { return }
        stop()
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        for (key, value) in [("v", "1"), ("id", hostID), ("hk", hostKey)] {
            let bytes = Array(value.utf8)
            _ = TXTRecordSetValue(&txt, key, UInt8(truncatingIfNeeded: bytes.count), bytes)
        }
        var ref: DNSServiceRef?
        let status = DNSServiceRegister(&ref, 0, 0, name, Self.serviceType, nil, nil, port.bigEndian,
                                        TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), nil, nil)
        self.status = status
        guard status == kDNSServiceErr_NoError, let ref else {
            logger.error("wireguard: bonjour registration failed (\(status, privacy: .public))")
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        registration = ref
        published = (port, hostID, hostKey)
        logger.info("wireguard: advertising \(Self.serviceType, privacy: .public) on UDP \(port, privacy: .public)")
    }

    public func stop() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
        published = nil
        status = nil
    }
}
