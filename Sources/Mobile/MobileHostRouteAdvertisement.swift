import CMUXMobileCore
import CmuxSettings
import Foundation

@MainActor
final class MobileHostRouteAdvertisement {
    nonisolated static let manualHostDefaultsKey = SettingCatalog().mobile.iOSPairingManualHost.userDefaultsKey

    private let routeResolver: MobileRouteResolver
    private var advertisedManualHost: String?

    init(routeResolver: MobileRouteResolver) {
        self.routeResolver = routeResolver
    }

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

    func publishCurrentRoutes(port: Int) -> [CmxAttachRoute] {
        let manualHost = Self.configuredManualHost()
        advertisedManualHost = manualHost
        return currentRoutes(port: port, manualHost: manualHost)
    }

    func publishCurrentRoutes(port: Int, tailscaleHosts: [String]) -> [CmxAttachRoute] {
        let manualHost = Self.configuredManualHost()
        advertisedManualHost = manualHost
        return currentRoutes(port: port, tailscaleHosts: tailscaleHosts, manualHost: manualHost)
    }

    func clearAdvertisedRoutes() -> [CmxAttachRoute] {
        advertisedManualHost = nil
        return []
    }

    func refreshAdvertisedRoutesIfNeeded(port: Int, defaults: UserDefaults = .standard) -> [CmxAttachRoute]? {
        let manualHost = Self.configuredManualHost(defaults: defaults)
        guard Self.manualHostNeedsRouteRefresh(previous: advertisedManualHost, current: manualHost) else {
            return nil
        }
        advertisedManualHost = manualHost
        return currentRoutes(port: port, manualHost: manualHost)
    }

    func reset() {
        advertisedManualHost = nil
    }
}
