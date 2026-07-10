import CFNetwork
import Foundation
import Network
import ObjectiveC
import WebKit

private var browserProxyConfigurationApplicationStateKey: UInt8 = 0

private enum BrowserProxyConfigurationApplicationState: Equatable {
    case pristineDirect
    case explicit(identity: String)
    case directAfterExplicit
}

@MainActor
private final class BrowserProxyConfigurationApplicationStateBox: NSObject {
    var state: BrowserProxyConfigurationApplicationState = .pristineDirect
}

/// The semantic network route applied to a browser website data store.
///
/// Application state is retained on the shared data store so equivalent
/// explicit routes can coalesce without treating direct routing as a durable
/// WebKit state.
struct BrowserProxyConfigurationRoute {
    private enum Kind {
        case direct
        case explicit(identity: String, configurations: [ProxyConfiguration])
    }

    private let kind: Kind

    static let direct = BrowserProxyConfigurationRoute(kind: .direct)

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
            kind: .explicit(
                identity: mirroredSystemIdentity(mirror),
                configurations: mirror.proxyConfigurations()
            )
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
            kind: .explicit(
                identity: "remote|\(identityComponent(host))|\(nwPort.rawValue)",
                configurations: [
                    ProxyConfiguration(socksv5Proxy: endpoint),
                    ProxyConfiguration(httpCONNECTProxy: endpoint),
                ]
            )
        )
    }

    @MainActor
    @discardableResult
    func apply(to websiteDataStore: WKWebsiteDataStore) -> Bool {
        let stateBox = applicationStateBox(for: websiteDataStore)
        switch kind {
        case .direct:
            switch stateBox.state {
            case .pristineDirect where websiteDataStore.proxyConfigurations.isEmpty:
                return false
            case .pristineDirect, .explicit, .directAfterExplicit:
                // WebKit clears only the live NetworkProcess configuration.
                // It retains the last explicit payload and can restore it after
                // that process relaunches, so a store that has ever been
                // explicit must keep direct routing re-clearable.
                websiteDataStore.proxyConfigurations = []
                stateBox.state = .directAfterExplicit
                return true
            }
        case .explicit(let identity, let configurations):
            if stateBox.state == .explicit(identity: identity) {
                return false
            }
            websiteDataStore.proxyConfigurations = configurations
            stateBox.state = .explicit(identity: identity)
            return true
        }
    }

    @MainActor
    private func applicationStateBox(
        for websiteDataStore: WKWebsiteDataStore
    ) -> BrowserProxyConfigurationApplicationStateBox {
        if let stateBox = objc_getAssociatedObject(
            websiteDataStore,
            &browserProxyConfigurationApplicationStateKey
        ) as? BrowserProxyConfigurationApplicationStateBox {
            return stateBox
        }
        let stateBox = BrowserProxyConfigurationApplicationStateBox()
        objc_setAssociatedObject(
            websiteDataStore,
            &browserProxyConfigurationApplicationStateKey,
            stateBox,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return stateBox
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
