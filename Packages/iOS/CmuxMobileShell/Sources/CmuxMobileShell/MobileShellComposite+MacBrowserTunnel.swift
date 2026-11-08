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
/// workspace belongs to, so a page can never leave through a sibling app
/// instance on the same Mac or through a different Mac.
extension MobileShellComposite {
    /// Capability a Mac advertises once it serves tunnel lanes (the Mac's
    /// `IrxTunnelCapability.current.identifier`).
    public static let macBrowserTunnelCapability = "browser.tunnel.v1"

    /// Tunnel availability for one exact app instance. A missing identity
    /// is unavailable; a missing tag names only a legacy untagged instance.
    public func macBrowserTunnelAvailability(pairingKey: MacPairingKey?) -> MacBrowserTunnelAvailability {
        guard connectionState == .connected,
              let pairingKey,
              let connected = connectedMacDeviceID,
              pairingKey == MacPairingKey(
                macDeviceID: connected,
                instanceTag: connectedMacInstanceTag
              ) else {
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
    public func prepareMacBrowserNetwork(pairingKey: MacPairingKey, loopbackPort: Int?) async throws -> Int {
        guard macBrowserTunnelAvailability(pairingKey: pairingKey) == .available else {
            throw MobileTunnelOpenFailure.unavailable
        }
        return try await macBrowserNetwork(for: pairingKey).prepare(loopbackPort: loopbackPort)
    }

    /// Stops every Mac browser network (sign-out).
    func stopMacBrowserNetworks() async {
        let networks = macBrowserNetworks.values
        macBrowserNetworks.removeAll()
        for network in networks { await network.stop() }
    }

    func macBrowserNetwork(for pairingKey: MacPairingKey) -> MobileMacBrowserNetwork {
        if let existing = macBrowserNetworks[pairingKey] { return existing }
        let network = MobileMacBrowserNetwork(
            pairingKey: pairingKey,
            openLane: { [weak self] host, port in
                let (provider, request) = try await MainActor.run { [weak self] in
                    guard let self else { throw MobileTunnelOpenFailure.unavailable }
                    return try self.macTunnelLaneTarget(pairingKey: pairingKey)
                }
                return try await provider.connect(request, host, port)
            },
            listPorts: { [weak self] in
                let (provider, request) = try await MainActor.run { [weak self] in
                    guard let self else { throw MobileTunnelOpenFailure.unavailable }
                    return try self.macTunnelLaneTarget(pairingKey: pairingKey)
                }
                return try await provider.listPorts(request)
            },
            // One loopback for SSH hosts and Macs alike, so a Mac's mirror
            // evicts an SSH host's forward on the same port and vice versa.
            registry: sshComputers.loopbackPorts
        )
        macBrowserNetworks[pairingKey] = network
        return network
    }

    /// The providers and transport request for one exact app instance,
    /// evaluated per lane so reconnects are picked up while another Mac or
    /// sibling app instance can never supply the browser's connection.
    func macTunnelLaneTarget(pairingKey: MacPairingKey) throws -> (MacTunnelProviders, CmxByteTransportRequest) {
        guard macBrowserTunnelAvailability(pairingKey: pairingKey) == .available,
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
