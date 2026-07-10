import CFNetwork
import Foundation
import Network
import ObjectiveC
import WebKit

private var browserProxyConfigurationApplicationStateKey: UInt8 = 0

/// The semantic network route applied to a browser website data store.
///
/// Application state is retained on the shared data store so equivalent
/// explicit routes can coalesce without treating direct routing as a durable
/// WebKit state.
struct BrowserProxyConfigurationRoute {
    private let configurations: [ProxyConfiguration]
    private let identity: String
    private let isDirect: Bool

    static let direct = BrowserProxyConfigurationRoute(
        configurations: [],
        identity: "direct",
        isDirect: true
    )

    static var currentSystem: BrowserProxyConfigurationRoute {
        guard let rawSettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let settings = rawSettings as NSDictionary as? [String: Any],
              let mirror = BrowserSystemProxyMirror(systemProxySettings: settings) else {
            return .direct
        }
        return mirroredSystem(mirror)
    }

    static func mirroredSystem(_ mirror: BrowserSystemProxyMirror) -> BrowserProxyConfigurationRoute {
        BrowserProxyConfigurationRoute(
            configurations: mirror.proxyConfigurations(),
            identity: mirroredSystemIdentity(mirror),
            isDirect: false
        )
    }

    static func remoteWorkspace(host rawHost: String, port: Int) -> BrowserProxyConfigurationRoute {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              port > 0 && port <= 65535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .direct
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        return BrowserProxyConfigurationRoute(
            configurations: [
                ProxyConfiguration(socksv5Proxy: endpoint),
                ProxyConfiguration(httpCONNECTProxy: endpoint),
            ],
            identity: "remote|\(identityComponent(host))|\(nwPort.rawValue)",
            isDirect: false
        )
    }

    @MainActor
    @discardableResult
    func apply(to websiteDataStore: WKWebsiteDataStore) -> Bool {
        let state = applicationState(for: websiteDataStore)
        if isDirect {
            switch state {
            case .pristineDirect where websiteDataStore.proxyConfigurations.isEmpty:
                return false
            case .pristineDirect, .explicit, .directAfterExplicit:
                // WebKit clears only the live NetworkProcess configuration.
                // It retains the last explicit payload and can restore it after
                // that process relaunches, so a store that has ever been
                // explicit must keep direct routing re-clearable.
                websiteDataStore.proxyConfigurations = []
                storeApplicationState(.directAfterExplicit, on: websiteDataStore)
                return true
            }
        }

        if state == .explicit(identity: identity) {
            return false
        }
        websiteDataStore.proxyConfigurations = configurations
        storeApplicationState(.explicit(identity: identity), on: websiteDataStore)
        return true
    }

    @MainActor
    private func applicationState(
        for websiteDataStore: WKWebsiteDataStore
    ) -> BrowserProxyConfigurationApplicationState {
        objc_getAssociatedObject(
            websiteDataStore,
            &browserProxyConfigurationApplicationStateKey
        ) as? BrowserProxyConfigurationApplicationState ?? .pristineDirect
    }

    @MainActor
    private func storeApplicationState(
        _ state: BrowserProxyConfigurationApplicationState,
        on websiteDataStore: WKWebsiteDataStore
    ) {
        objc_setAssociatedObject(
            websiteDataStore,
            &browserProxyConfigurationApplicationStateKey,
            state,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func mirroredSystemIdentity(_ mirror: BrowserSystemProxyMirror) -> String {
        let proxyIdentity: String
        switch mirror.proxy {
        case .socksV5(let host, let port):
            proxyIdentity = "socks|\(identityComponent(host))|\(port)"
        case .httpCONNECT(let host, let port):
            proxyIdentity = "connect|\(identityComponent(host))|\(port)"
        }
        let exclusions = mirror.excludedDomains.map(identityComponent).joined(separator: "|")
        return "system|\(proxyIdentity)|\(exclusions)"
    }

    private static func identityComponent(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}
