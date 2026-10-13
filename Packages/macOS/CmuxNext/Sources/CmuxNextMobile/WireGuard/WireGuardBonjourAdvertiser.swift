public import Foundation
import CmuxNextWakeups
import Network
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
    private var selfCheck: NWBrowser?
    private let selfCheckDeadline = DemandTimer(owner: "mobile.wireguard.bonjour-check")
    /// nil while not advertising or not yet confirmed; true once this Mac's
    /// own record is seen on the network; false when registration or the
    /// check failed (usually Local Network access is off for the app).
    public private(set) var discoverable: Bool?
    /// Called on the main actor when `discoverable` changes.
    public var onChange: (() -> Void)?
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
        guard status == kDNSServiceErr_NoError, let ref else {
            logger.error("wireguard: bonjour registration failed (\(status, privacy: .public))")
            setDiscoverable(false)
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        registration = ref
        published = (port, hostID, hostKey)
        checkVisible(hostID: hostID)
        logger.info("wireguard: advertising \(Self.serviceType, privacy: .public) on UDP \(port, privacy: .public)")
    }

    /// Browses for this Mac's own record: a registration the system filters
    /// (Local Network access off) succeeds but never appears.
    private func checkVisible(hostID: String) {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .udp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let seen = results.contains { result in
                if case .bonjour(let txt) = result.metadata { return txt["id"] == hostID }
                return false
            }
            guard seen else { return }
            // task-owner: main-actor hop for one state update
            Task { @MainActor in self?.setDiscoverable(true) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .waiting:
                // task-owner: main-actor hop for one state update
                Task { @MainActor in self?.setDiscoverable(false) }
            default:
                break
            }
        }
        browser.start(queue: queue)
        selfCheck = browser
        // Unseen after 5 s: the system is filtering the record.
        selfCheckDeadline.schedule(after: .seconds(5)) { @MainActor [weak self] in
            guard let self, self.discoverable == nil else { return }
            self.setDiscoverable(false)
        }
    }

    private func setDiscoverable(_ value: Bool?) {
        guard discoverable != value else { return }
        discoverable = value
        onChange?()
    }

    public func stop() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
        published = nil
        selfCheck?.cancel()
        selfCheck = nil
        selfCheckDeadline.cancel()
        setDiscoverable(nil)
    }
}
