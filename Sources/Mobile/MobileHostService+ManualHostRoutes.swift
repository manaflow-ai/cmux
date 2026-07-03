import CMUXMobileCore
import Foundation

extension MobileHostService {
    /// User-default key for the explicit manual host advertised to iOS when
    /// Tailscale is unavailable on this Mac.
    nonisolated static let manualHostDefaultsKey = MobileHostRouteAdvertisement.manualHostDefaultsKey

    /// The user-configured LAN/DNS host to advertise as an explicit manual route,
    /// or `nil` when unset or invalid.
    nonisolated static func configuredManualHost(defaults: UserDefaults = .standard) -> String? {
        MobileHostRouteAdvertisement.configuredManualHost(defaults: defaults)
    }

    nonisolated static func manualHostNeedsRouteRefresh(previous: String?, current: String?) -> Bool {
        MobileHostRouteAdvertisement.manualHostNeedsRouteRefresh(previous: previous, current: current)
    }

    func currentRoutes(port: Int) -> [CmxAttachRoute] {
        routeAdvertisement.currentRoutes(port: port)
    }

    func currentRoutes(port: Int, manualHost: String?) -> [CmxAttachRoute] {
        routeAdvertisement.currentRoutes(port: port, manualHost: manualHost)
    }

    func currentRoutes(port: Int, tailscaleHosts: [String]) -> [CmxAttachRoute] {
        routeAdvertisement.currentRoutes(port: port, tailscaleHosts: tailscaleHosts)
    }

    func currentRoutes(port: Int, tailscaleHosts: [String], manualHost: String?) -> [CmxAttachRoute] {
        routeAdvertisement.currentRoutes(port: port, tailscaleHosts: tailscaleHosts, manualHost: manualHost)
    }

    func publishCurrentRoutes(port: Int) {
        updatePublicStatusSnapshot(routes: routeAdvertisement.publishCurrentRoutes(port: port))
    }

    func publishCurrentRoutes(port: Int, tailscaleHosts: [String]) {
        updatePublicStatusSnapshot(
            routes: routeAdvertisement.publishCurrentRoutes(port: port, tailscaleHosts: tailscaleHosts)
        )
    }

    func clearAdvertisedRoutes() {
        updatePublicStatusSnapshot(routes: routeAdvertisement.clearAdvertisedRoutes())
    }

    func refreshAdvertisedRoutesIfRunning(defaults: UserDefaults = .standard) {
        guard let listenerPort else {
            return
        }
        guard let routes = routeAdvertisement.refreshAdvertisedRoutesIfNeeded(
            port: listenerPort,
            defaults: defaults
        ) else {
            return
        }
        updatePublicStatusSnapshot(routes: routes)
    }
}
