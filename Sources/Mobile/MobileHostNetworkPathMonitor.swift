import Foundation
@preconcurrency import Network

/// Watches the system network path for the mobile pairing host and reports
/// deduplicated path changes on the main actor.
///
/// The pairing listener stays bound when the Mac moves networks or Tailscale
/// flips, so the advertised route set (and the team device registry that
/// ``DeviceRegistryClient`` mirrors from `statusUpdates()`) needs an explicit
/// trigger to refresh; ``MobileHostService`` owns the republish action and
/// this type owns the observation: one `NWPathMonitor`, a path signature for
/// duplicate suppression, and nothing else.
///
/// Every observation that differs from the previous one fires `onPathChange`,
/// *including the first*: the initial callback can arrive after the
/// listener-ready route publish and describe a different path than those
/// routes were computed on (e.g. Tailscale came up in between), so treating
/// it as a silent baseline would swallow that first real change. Republishing
/// is cheap because downstream consumers dedup unchanged routes; only an
/// observation identical to the previous one is skipped (`NWPathMonitor` can
/// deliver duplicate callbacks).
///
/// The signature includes the local IPv4 addresses (from `getifaddrs`) on top
/// of `NWPath`'s status/interfaces/gateways: two networks can present the same
/// interface name and gateway address (two home LANs both using `en0` and
/// `192.168.1.1`) while assigning a different local address, and the advertised
/// routes are built from the local addresses. IPv6 is deliberately excluded:
/// RFC 4941 temporary addresses rotate while the path is otherwise unchanged,
/// which would turn rotation churn into spurious republishes, and an IPv6
/// renumbering that matters for routes accompanies an interface/gateway/IPv4
/// change in practice.
@MainActor
final class MobileHostNetworkPathMonitor {
    private let monitor = NWPathMonitor()
    /// Signature of the last observed path, for duplicate suppression.
    private var lastSignature: String?
    private let onPathChange: @MainActor () -> Void
    /// Returns the machine's local IPv4 addresses; injectable for tests.
    /// Called on the monitor queue, off-main.
    private let localIPv4Addresses: @Sendable () -> [String]

    init(
        onPathChange: @escaping @MainActor () -> Void,
        localIPv4Addresses: @escaping @Sendable () -> [String] = {
            MobileHostNetworkPathMonitor.systemLocalIPv4Addresses()
        }
    ) {
        self.onPathChange = onPathChange
        self.localIPv4Addresses = localIPv4Addresses
    }

    /// Begin observing. The handler computes the signature off-main (on
    /// `queue`) and hops to the main actor for dedup state and the callback.
    func start(queue: DispatchQueue) {
        monitor.pathUpdateHandler = { [weak self, localIPv4Addresses] path in
            let signature = Self.signature(
                status: String(describing: path.status),
                interfaceNames: path.availableInterfaces.map(\.name),
                gateways: path.gateways.map { String(describing: $0) },
                localAddresses: localIPv4Addresses()
            )
            Task { @MainActor [weak self] in
                self?.handleObservation(signature: signature)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private func handleObservation(signature: String) {
        let changed = Self.shouldReportPathChange(
            previousSignature: lastSignature,
            newSignature: signature
        )
        lastSignature = signature
        guard changed else { return }
        onPathChange()
    }

    /// Stable identity of a network path for change detection. Order-insensitive
    /// over interfaces, gateways, and local addresses so enumeration order can't
    /// fake a change. Pure for tests.
    nonisolated static func signature(
        status: String,
        interfaceNames: [String],
        gateways: [String],
        localAddresses: [String]
    ) -> String {
        let interfaces = interfaceNames.sorted().joined(separator: ",")
        let gatewayList = gateways.sorted().joined(separator: ",")
        let addresses = localAddresses.sorted().joined(separator: ",")
        return "\(status)|\(interfaces)|\(gatewayList)|\(addresses)"
    }

    /// Local IPv4 addresses of all up, non-loopback interfaces (see the type
    /// doc for why IPv6 is excluded). Sorted by ``signature(status:interfaceNames:gateways:localAddresses:)``,
    /// so order here does not matter.
    nonisolated static func systemLocalIPv4Addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            addresses.append(String(cString: host))
        }
        return addresses
    }

    /// Whether a path observation should be reported: any observation that
    /// differs from the previous one, including the first (see the type doc
    /// for why the first observation is not a silent baseline). Pure for tests.
    nonisolated static func shouldReportPathChange(
        previousSignature: String?,
        newSignature: String
    ) -> Bool {
        previousSignature != newSignature
    }
}
