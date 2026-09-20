import Foundation

/// Localized, actionable copy for a Ports group that cannot show a trustworthy
/// list or route. The model is independent of AppKit so the state matrix stays
/// testable without constructing an outline view.
struct CloudPortsStatusPresentation: Equatable {
    enum Action: Equatable {
        case none
        case refresh
        case openMachine
        case openShell
    }

    let title: String
    let message: String
    let action: Action
    let actionTitle: String?

    static func make(info: SurfaceMachineInfo) -> Self {
        if case .notRequested = info.portDiscoveryState {
            switch info.linkState {
            case .connecting:
                return Self(
                    title: String(localized: "cloudTree.ports.loading", defaultValue: "Discovering ports…"),
                    message: String(localized: "cloudTree.ports.loading.detail", defaultValue: "cmux is reading the machine’s listening services."),
                    action: .none,
                    actionTitle: nil
                )
            case .error:
                return Self(
                    title: String(localized: "cloudTree.ports.failed", defaultValue: "Cloud link unavailable"),
                    message: info.linkError ?? String(localized: "cloudTree.ports.failed", defaultValue: "Reconnect the machine or refresh to discover ports again."),
                    action: .refresh,
                    actionTitle: String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")
                )
            case .asleep:
                return Self(
                    title: String(localized: "cloudTree.ports.asleep", defaultValue: "Machine is asleep"),
                    message: String(localized: "cloudTree.ports.asleep.detail", defaultValue: "Wake the machine to discover its listening services."),
                    action: .openMachine,
                    actionTitle: String(localized: "cloudTree.ports.action.wake", defaultValue: "Wake Machine")
                )
            case .unavailable:
                return Self(
                    title: String(localized: "cloudTree.ports.unavailable", defaultValue: "Port discovery unavailable"),
                    message: String(localized: "cloudTree.ports.unavailable.detail", defaultValue: "Refresh to retry port discovery."),
                    action: .refresh,
                    actionTitle: String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")
                )
            case .connected, .notApplicable:
                break
            }
        }
        let routeNote = String(
            localized: "cloudTree.ports.routeNote",
            defaultValue: "cmux’s authenticated in-app forwarding works without the system-wide Cloud VPN. Safari, Chrome, and other Mac apps using the machine’s private address do require Cloud VPN."
        )
        switch info.portDiscoveryState {
        case .notRequested:
                return Self(
                    title: String(localized: "cloudTree.ports.empty", defaultValue: "No reachable ports"),
                    message: String(localized: "cloudTree.ports.notRequested", defaultValue: "Expand this group to scan the machine for reachable services."),
                action: .none,
                actionTitle: nil
            )
        case .loading:
            return Self(
                title: String(localized: "cloudTree.ports.loading", defaultValue: "Discovering ports…"),
                message: String(localized: "cloudTree.ports.loading.detail", defaultValue: "cmux is reading the machine’s listening services."),
                action: .none,
                actionTitle: nil
            )
        case .available:
            return Self(
                title: String(localized: "cloudTree.ports.empty", defaultValue: "No reachable ports"),
                message: routeNote,
                action: .none,
                actionTitle: nil
            )
        case .empty(let reason):
            switch reason {
            case .noListeningService:
                return Self(
                    title: String(localized: "cloudTree.ports.empty", defaultValue: "No reachable ports"),
                    message: String(
                        format: String(localized: "cloudTree.ports.empty.noService", defaultValue: "No service is listening on a reachable port. Start an HTTP service on the machine, then refresh. %@"),
                        routeNote
                    ),
                    action: .refresh,
                    actionTitle: String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")
                )
            case .loopbackOnly:
                return Self(
                    title: String(localized: "cloudTree.ports.empty", defaultValue: "No reachable ports"),
                    message: String(
                        format: String(localized: "cloudTree.ports.empty.loopback", defaultValue: "A service is listening only on loopback. Bind it to the machine network, then refresh. %@"),
                        routeNote
                    ),
                    action: .refresh,
                    actionTitle: String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")
                )
            }
        case .unavailable(let reason):
            switch reason {
            case .privateAddress:
                let privateAddressMessage = String(
                    format: String(localized: "cloudTree.port.noPrivateAddress", defaultValue: "%@ has no private network address yet; refresh the machine list and retry."),
                    info.id.rawValue
                )
                return Self(
                    title: String(localized: "cloudTree.ports.privateAddress", defaultValue: "Private address unavailable"),
                    message: "\(privateAddressMessage) \(routeNote)",
                    action: .refresh,
                    actionTitle: String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")
                )
            case .machineAsleep:
                return Self(
                    title: String(localized: "cloudTree.ports.asleep", defaultValue: "Open the machine to discover ports"),
                    message: String(localized: "cloudTree.ports.asleep.detail", defaultValue: "Wake the machine to discover its listening services."),
                    action: .openMachine,
                    actionTitle: String(localized: "cloudTree.ports.action.wake", defaultValue: "Wake Machine")
                )
            case .link:
                let linkMessage = String(localized: "cloudTree.ports.failed", defaultValue: "Couldn’t discover ports. Refresh to retry.")
                return Self(
                    title: String(localized: "cloudTree.ports.failed", defaultValue: "Couldn’t discover ports. Refresh to retry."),
                    message: "\(linkMessage) \(routeNote)",
                    action: .refresh,
                    actionTitle: String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")
                )
            case .transport:
                let transportMessage = String(localized: "cloudTree.ports.unavailable", defaultValue: "Port discovery unavailable. Refresh to retry.")
                return Self(
                    title: String(localized: "cloudTree.ports.unavailable", defaultValue: "Port discovery unavailable. Refresh to retry."),
                    message: "\(transportMessage) \(routeNote)",
                    action: .refresh,
                    actionTitle: String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh Ports")
                )
            case .hub:
                return Self(
                    title: String(localized: "cloudTree.ports.unavailable", defaultValue: "Port discovery unavailable. Refresh to retry."),
                    message: String(localized: "cloudTree.ports.hub.detail", defaultValue: "This build cannot start cmux’s authenticated Cloud forward. Update cmux, then retry."),
                    action: .refresh,
                    actionTitle: String(localized: "common.retry", defaultValue: "Retry")
                )
            }
        case .stale:
            return Self(
                title: String(localized: "cloudTree.ports.stale", defaultValue: "Port list may be out of date"),
                message: String(
                    format: String(localized: "cloudTree.ports.stale.detail", defaultValue: "Reconnect or refresh before relying on this list. %@"),
                    routeNote
                ),
                action: .refresh,
                actionTitle: String(localized: "cloudTree.menu.refresh", defaultValue: "Refresh")
            )
        case .unsupported:
            return Self(
                title: String(localized: "cloudTree.ports.unsupported", defaultValue: "Ports are not supported by this provider."),
                message: String(format: String(localized: "cloudTree.port.unsupported", defaultValue: "%@’s provider cannot open machine ports as previews; reach the service from inside the machine with `cmux vm exec %@ -- …`."), info.id.rawValue, info.id.rawValue),
                action: .openShell,
                actionTitle: String(localized: "machines.menu.openShell", defaultValue: "Open Shell")
            )
        }
    }
}
