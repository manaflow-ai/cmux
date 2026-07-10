import CFNetwork
import Foundation
import Network
import ObjectiveC
import WebKit

private var browserProxyConfigurationIdentityKey: UInt8 = 0

/// The semantic network route applied to a browser website data store.
///
/// Route identity is retained on the shared data store because assigning
/// WebKit's `proxyConfigurations` rebuilds that store's networking session,
/// even when the new array is empty or semantically identical.
struct BrowserProxyConfigurationRoute {
    private let configurations: [ProxyConfiguration]
    private let identity: String

    static let direct = BrowserProxyConfigurationRoute(configurations: [], identity: "direct")

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
            identity: mirroredSystemIdentity(mirror)
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
            identity: "remote|\(identityComponent(host))|\(nwPort.rawValue)"
        )
    }

    @MainActor
    @discardableResult
    func apply(to websiteDataStore: WKWebsiteDataStore) -> Bool {
        let previousIdentity = objc_getAssociatedObject(
            websiteDataStore,
            &browserProxyConfigurationIdentityKey
        ) as? String
        guard previousIdentity != identity else {
            return false
        }

        if identity == "direct", websiteDataStore.proxyConfigurations.isEmpty {
            storeIdentity(on: websiteDataStore)
            return false
        }

        websiteDataStore.proxyConfigurations = configurations
        storeIdentity(on: websiteDataStore)
        return true
    }

    @MainActor
    private func storeIdentity(on websiteDataStore: WKWebsiteDataStore) {
        objc_setAssociatedObject(
            websiteDataStore,
            &browserProxyConfigurationIdentityKey,
            identity as NSString,
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
