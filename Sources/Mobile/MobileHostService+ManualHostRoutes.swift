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
              let host = CmxManualHost(raw)?.rawValue else {
            return nil
        }
        return host
    }

    func currentRoutes(port: Int) -> [CmxAttachRoute] {
        routeResolver.routes(port: port, manualHost: Self.configuredManualHost()).routes
    }

    func currentRoutes(port: Int, tailscaleHosts: [String]) -> [CmxAttachRoute] {
        routeResolver.routes(
            port: port,
            tailscaleHosts: tailscaleHosts,
            manualHost: Self.configuredManualHost()
        ).routes
    }

    func refreshAdvertisedRoutesIfRunning() {
        guard let listenerPort else {
            return
        }
        MobileHostPublicStatusCache.update(routes: currentRoutes(port: listenerPort))
    }
}
