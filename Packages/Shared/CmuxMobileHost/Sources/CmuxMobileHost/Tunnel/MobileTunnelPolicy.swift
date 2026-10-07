public import CmuxMobileWire

/// Default deny for loopback forwards: a port is forwardable only when it is
/// unprivileged, not denied, and in the Mac's directory at the moment of the
/// check. The phone names a port only; the host is always this Mac's loopback.
public struct MobileTunnelPolicy: Sendable {
    public static let firstUnprivilegedPort: UInt16 = 1024

    public let configuration: MobileTunnelConfiguration

    public init(configuration: MobileTunnelConfiguration) {
        self.configuration = configuration
    }

    public func check(_ port: UInt16, advertised: [TunnelPort]) -> Result<TunnelPort, MobileTunnelRefusal> {
        guard port >= Self.firstUnprivilegedPort else { return .failure(.privileged) }
        guard !configuration.deniedPorts.contains(port) else { return .failure(.denied) }
        guard let entry = advertised.first(where: { $0.port == port }) else { return .failure(.notAdvertised) }
        return .success(entry)
    }

    /// The directory's entries this policy admits, in port order.
    public func admitted(_ advertised: [TunnelPort]) -> [TunnelPort] {
        advertised
            .filter { if case .success = check($0.port, advertised: advertised) { true } else { false } }
            .sorted { $0.port < $1.port }
    }
}
