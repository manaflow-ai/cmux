public import CMUXMobileCore
public import CmuxMobileRPC
import Foundation

/// Whether a Mac workspace's native browser can load pages through its Mac.
public enum MacBrowserTunnelAvailability: Equatable, Sendable {
    case available
    /// Not connected to that Mac right now (transient).
    case notConnected
    /// The connected Mac predates the tunnel.
    case needsMacUpdate
    /// Connected over a route without tunnel lanes (the Tailscale TCP
    /// fallback).
    case routeWithoutLanes

    /// Whether a native browser in that Mac's workspace is bound to the Mac.
    /// A transient disconnect keeps the binding (loads fail until the Mac is
    /// back) so a page never silently switches networks mid-session.
    public var bindsBrowserToMac: Bool {
        self == .available || self == .notConnected
    }
}

/// The "On iPhone" browser for paired-Mac workspaces: the phone's native
/// browser reaches the network through the Mac (see
/// ``MobileMacBrowserNetwork``). Tunnel lanes ride the admitted irx session
/// of the foreground connection; every lane is re-bound to the exact Mac the
/// workspace belongs to, so a page can never leave through a different Mac.
extension MobileShellComposite {
    /// Capability a Mac advertises once it serves tunnel lanes (the Mac's
    /// `IrxTunnelCapability.identifier`).
    public static let macBrowserTunnelCapability = "browser.tunnel.v1"

    /// Tunnel availability for a workspace on `macDeviceID` (nil means the
    /// connected Mac).
    public func macBrowserTunnelAvailability(macDeviceID: String?) -> MacBrowserTunnelAvailability {
        guard connectionState == .connected,
              let connected = connectedMacDeviceID,
              macDeviceID == nil || macDeviceID == connected else {
            return .notConnected
        }
        guard supportedHostCapabilities.contains(Self.macBrowserTunnelCapability) else {
            return .needsMacUpdate
        }
        guard activeRoute?.kind == .iroh,
              runtime?.tunnelConnectProvider != nil,
              runtime?.tunnelListeningPortsProvider != nil else {
            return .routeWithoutLanes
        }
        return .available
    }

    /// Readies the Mac browser network for a navigation and returns the
    /// phone-side SOCKS proxy port for the browser's data store.
    public func prepareMacBrowserNetwork(macDeviceID: String, loopbackPort: Int?) async throws -> Int {
        try await macBrowserNetwork(for: macDeviceID).prepare(loopbackPort: loopbackPort)
    }

    /// Stops every Mac browser network (sign-out).
    func stopMacBrowserNetworks() async {
        let networks = macBrowserNetworks.values
        macBrowserNetworks.removeAll()
        for network in networks { await network.stop() }
    }

    func macBrowserNetwork(for macDeviceID: String) -> MobileMacBrowserNetwork {
        if let existing = macBrowserNetworks[macDeviceID] { return existing }
        let network = MobileMacBrowserNetwork(
            macDeviceID: macDeviceID,
            openLane: { [weak self] host, port in
                let (provider, request) = try await MainActor.run { [weak self] in
                    guard let self else { throw MobileTunnelOpenFailure.unavailable }
                    return try self.macTunnelLaneTarget(macDeviceID: macDeviceID)
                }
                return try await provider.connect(request, host, port)
            },
            listPorts: { [weak self] in
                let (provider, request) = try await MainActor.run { [weak self] in
                    guard let self else { throw MobileTunnelOpenFailure.unavailable }
                    return try self.macTunnelLaneTarget(macDeviceID: macDeviceID)
                }
                return try await provider.listPorts(request)
            }
        )
        macBrowserNetworks[macDeviceID] = network
        return network
    }

    /// The providers and the transport request for a lane to `macDeviceID`,
    /// evaluated per lane so a reconnect (or a switch to another Mac) is
    /// picked up, and a lane is never opened to any other Mac.
    func macTunnelLaneTarget(macDeviceID: String) throws -> (MacTunnelProviders, CmxByteTransportRequest) {
        guard macBrowserTunnelAvailability(macDeviceID: macDeviceID) == .available,
              let activeTicket,
              let activeRoute,
              let connect = runtime?.tunnelConnectProvider,
              let listPorts = runtime?.tunnelListeningPortsProvider else {
            throw MobileTunnelOpenFailure.unavailable
        }
        let request = CmxByteTransportRequest(
            route: activeRoute,
            expectedPeerDeviceID: activeTicket.macDeviceID,
            authorizationMode: .transportAdmission,
            sessionPurpose: .featureLane
        )
        return (MacTunnelProviders(connect: connect, listPorts: listPorts), request)
    }
}

struct MacTunnelProviders: Sendable {
    let connect: MobileTunnelConnectProvider
    let listPorts: MobileTunnelListeningPortsProvider
}
