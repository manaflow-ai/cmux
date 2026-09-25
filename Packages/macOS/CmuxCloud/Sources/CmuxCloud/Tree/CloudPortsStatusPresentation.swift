import CmuxSurfaceCatalogModel
import Foundation

/// One immutable Ports reason shared by native status rows and their actions.
public struct CloudPortsStatusPresentation: Equatable, Sendable {
    public let state: CloudPortDiscoveryState
    public let isVPNGuidance: Bool

    public init(state: CloudPortDiscoveryState, isVPNGuidance: Bool = false) {
        self.state = state
        self.isVPNGuidance = isVPNGuidance
    }

    public static var vpnGuidance: Self {
        Self(state: .available, isVPNGuidance: true)
    }

    public static func make(info: SurfaceMachineInfo) -> Self {
        if info.portDiscoveryState == .notRequested {
            switch info.linkState {
            case .asleep: return Self(state: .unavailable(.machineAsleep))
            case .error: return Self(state: .unavailable(.link))
            case .unavailable: return Self(state: .unavailable(.transport))
            default: break
            }
        }
        return Self(state: info.portDiscoveryState)
    }

    public var title: String {
        if isVPNGuidance {
            return String(localized: "cloud.ports.vpnOff.title", defaultValue: "Cloud VPN is off")
        }
        switch state {
        case .notRequested:
            return String(localized: "cloudTree.ports.notRequested.title", defaultValue: "Ports not checked yet")
        case .loading:
            return String(localized: "cloudTree.ports.loading", defaultValue: "Discovering ports…")
        case .available:
            return String(localized: "cloudTree.ports.available.title", defaultValue: "Listening services")
        case .loopbackOnly:
            return String(localized: "cloudTree.ports.loopback.title", defaultValue: "Loopback services available")
        case .empty(.noListeningService):
            return String(localized: "cloudTree.ports.empty", defaultValue: "No reachable ports")
        case .empty(.otherInterfaceOnly):
            return String(localized: "cloudTree.ports.binding.title", defaultValue: "Services use another interface")
        case .unavailable(.privateAddress):
            return String(localized: "cloudTree.ports.privateAddress", defaultValue: "Private address unavailable")
        case .unavailable(.machineAsleep):
            return String(localized: "cloudTree.ports.asleep", defaultValue: "Open the machine to discover ports")
        case .unavailable(.link):
            return String(localized: "cloudTree.ports.link.title", defaultValue: "Cloud link unavailable")
        case .unavailable:
            return String(localized: "cloudTree.ports.unavailable", defaultValue: "Port discovery unavailable. Refresh to retry.")
        case .stale:
            return String(localized: "cloudTree.ports.stale", defaultValue: "Port list may be out of date")
        case .unsupported:
            return String(localized: "cloudTree.ports.unsupported", defaultValue: "Ports are not supported by this provider.")
        }
    }

    public var message: String {
        if isVPNGuidance {
            return String(
                localized: "cloud.ports.vpnOff.explanation",
                defaultValue: "cmux’s in-app forwarding works without a system VPN. Cloud VPN lets Safari, Chrome, and other apps open private VM ports."
            )
        }
        switch state {
        case .notRequested:
            return Self.routeNote
        case .loading:
            return String(localized: "cloudTree.ports.loading.detail", defaultValue: "Checking services through cmux’s authenticated Cloud link. No system VPN is needed.")
        case .available:
            return Self.routeNote
        case .loopbackOnly:
            return String(localized: "cloudTree.ports.loopback.detail", defaultValue: "These services open in cmux without Cloud VPN. They listen on the machine’s loopback address, so other apps cannot reach them through its private IP, even with VPN connected.")
        case .empty(.noListeningService):
            return String(localized: "cloudTree.ports.empty.noService", defaultValue: "No application service is listening. Start an HTTP service on the machine, then refresh. cmux’s in-app forwarding does not need Cloud VPN.")
        case .empty(.otherInterfaceOnly):
            return String(localized: "cloudTree.ports.binding.detail", defaultValue: "cmux’s browser route connects to 127.0.0.1 on the machine. Bind the service to 127.0.0.1 or 0.0.0.0, then refresh. Turning on Cloud VPN does not change this route.")
        case .unavailable(.privateAddress):
            return String(localized: "cloudTree.ports.privateAddress.detail", defaultValue: "cmux’s authenticated route needs this machine’s private address. Refresh to retrieve it. Turning on Cloud VPN does not assign a missing address.")
        case .unavailable(.machineAsleep):
            return String(localized: "cloudTree.ports.asleep.detail", defaultValue: "Wake the machine to check its services. cmux’s in-app forwarding does not need Cloud VPN.")
        case .unavailable(.link):
            return String(localized: "cloudTree.ports.link.detail", defaultValue: "Port discovery could not connect to this machine. Existing cmux ports may still work. Refresh to reconnect; Cloud VPN is not required.")
        case .unavailable(.transport):
            return String(localized: "cloudTree.ports.unavailable.detail", defaultValue: "The port scan failed; this does not mean no service is listening. Existing cmux ports may still work. Refresh to retry; Cloud VPN is not required.")
        case .unavailable(.hub):
            return String(localized: "cloudTree.ports.hub.detail", defaultValue: "This build cannot start cmux’s authenticated Cloud forward. Update cmux, then retry.")
        case .stale:
            return String(localized: "cloudTree.ports.stale.detail", defaultValue: "The last scan could not be refreshed. Listed services may have changed; refresh to check again. cmux forwarding does not need Cloud VPN.")
        case .unsupported:
            return String(localized: "cloudTree.ports.unsupported.detail", defaultValue: "This provider has no supported in-app port route. Open a shell to access the service inside the machine. Cloud VPN does not add provider support.")
        }
    }

    public static var routeNote: String {
        String(localized: "cloudTree.ports.routeNote", defaultValue: "cmux forwards ports without Cloud VPN. Safari, Chrome, and other Mac apps need Cloud VPN to reach services bound to the machine’s private address.")
    }

    public var action: CloudPortsStatusAction {
        if isVPNGuidance { return .setupVPN }
        switch state {
        case .unavailable(.machineAsleep): return .openMachine
        case .unsupported: return .openShell
        case .loading, .available, .loopbackOnly: return .none
        default: return .refresh
        }
    }

    public var actionTitle: String? {
        switch action {
        case .none: return nil
        case .refresh: return String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")
        case .setupVPN: return String(localized: "cloudTree.ports.setupVPN", defaultValue: "Set Up VPN…")
        case .openMachine: return String(localized: "cloudTree.ports.action.wake", defaultValue: "Wake Machine")
        case .openShell: return String(localized: "machines.menu.openShell", defaultValue: "Open Shell")
        }
    }

    public var style: CloudTreePlaceholder.Style {
        if isVPNGuidance { return .dimmed }
        switch state {
        case .loading: return .connecting
        case .unavailable(.machineAsleep), .notRequested, .available, .loopbackOnly, .empty, .unsupported: return .dimmed
        case .unavailable, .stale: return .error
        }
    }
}
