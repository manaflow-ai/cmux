import CMUXMobileCore
import CmuxSettings
import Foundation

extension MobileHostService {
    /// User-default key for the explicit manual host advertised to iOS when
    /// Tailscale is unavailable on this Mac.
    nonisolated static let manualHostDefaultsKey = SettingCatalog().mobile.iOSPairingManualHost.userDefaultsKey

    /// The user-configured LAN/DNS host to advertise as an explicit manual route,
    /// or `nil` when unset or invalid.
    nonisolated static func configuredManualHost(defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.object(forKey: manualHostDefaultsKey) as? String,
              let host = CmxManualHost(raw)?.rawValue,
              !CmxLoopbackHost().matches(host) else {
            return nil
        }
        return host
    }

    nonisolated static func manualHostNeedsRouteRefresh(previous: String?, current: String?) -> Bool {
        previous != current
    }

    func currentRoutes(port: Int) -> [CmxAttachRoute] {
        currentRoutes(port: port, manualHost: Self.configuredManualHost())
    }

    func currentRoutes(port: Int, manualHost: String?) -> [CmxAttachRoute] {
        routeResolver.routes(port: port, manualHost: manualHost).routes
    }

    func currentRoutes(port: Int, tailscaleHosts: [String]) -> [CmxAttachRoute] {
        currentRoutes(port: port, tailscaleHosts: tailscaleHosts, manualHost: Self.configuredManualHost())
    }

    func currentRoutes(port: Int, tailscaleHosts: [String], manualHost: String?) -> [CmxAttachRoute] {
        routeResolver.routes(
            port: port,
            tailscaleHosts: tailscaleHosts,
            manualHost: manualHost
        ).routes
    }

    func publishCurrentRoutes(port: Int) {
        let manualHost = Self.configuredManualHost()
        advertisedManualHost = manualHost
        MobileHostPublicStatusCache.update(routes: currentRoutes(port: port, manualHost: manualHost))
    }

    func publishCurrentRoutes(port: Int, tailscaleHosts: [String]) {
        let manualHost = Self.configuredManualHost()
        advertisedManualHost = manualHost
        MobileHostPublicStatusCache.update(
            routes: currentRoutes(port: port, tailscaleHosts: tailscaleHosts, manualHost: manualHost)
        )
    }

    func clearAdvertisedRoutes() {
        advertisedManualHost = nil
        MobileHostPublicStatusCache.update(routes: [])
    }

    func refreshAdvertisedRoutesIfRunning(defaults: UserDefaults = .standard) {
        guard let listenerPort else {
            return
        }
        let manualHost = Self.configuredManualHost(defaults: defaults)
        guard Self.manualHostNeedsRouteRefresh(previous: advertisedManualHost, current: manualHost) else {
            return
        }
        advertisedManualHost = manualHost
        MobileHostPublicStatusCache.update(routes: currentRoutes(port: listenerPort, manualHost: manualHost))
    }
}
