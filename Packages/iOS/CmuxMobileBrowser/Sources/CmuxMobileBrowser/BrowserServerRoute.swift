#if canImport(WebKit)
public import Foundation
import Network
public import WebKit

/// Sends a native browser's traffic through one SSH computer, so pages load
/// as if browsed on it: its `localhost`, every port, and names only it can
/// resolve, with each page's real origin.
///
/// One route per computer, shared by every native browser opened for it.
/// Its website data store is non-persistent and private to that computer:
/// cookies and storage never mix across computers or with Mac and local
/// browsing, and they last until the app quits.
///
/// The data store carries a SOCKS5 proxy (the computer's `ssh -D`). The
/// system never proxies loopback addresses, so for `localhost` pages the
/// route also asks the computer to mirror its listening ports onto the
/// phone's loopback (see `prepare`).
@MainActor
public final class BrowserServerRoute {
    /// Readies the computer side for a load: the proxy, plus loopback port
    /// forwards when `loopbackPort` is set. Returns the proxy port.
    public typealias Prepare = @MainActor (_ loopbackPort: Int?) async throws -> Int

    public let id: String
    public let dataStore: WKWebsiteDataStore
    private var prepare: Prepare
    private var appliedProxyPort: Int?
    /// Loopback ports readied since the last connection change.
    private(set) var readiedLoopbackPorts: Set<Int> = []

    private static var routes: [String: BrowserServerRoute] = [:]

    private init(id: String, prepare: @escaping Prepare) {
        self.id = id
        self.prepare = prepare
        dataStore = .nonPersistent()
    }

    /// The route for computer `id`, created on first use. Later calls keep
    /// the same data store (so cookies survive switching browsers) and adopt
    /// the newest `prepare`.
    public static func route(id: String, prepare: @escaping Prepare) -> BrowserServerRoute {
        if let existing = routes[id] {
            existing.prepare = prepare
            return existing
        }
        let route = BrowserServerRoute(id: id, prepare: prepare)
        routes[id] = route
        return route
    }

    /// Readies the network for loading `url` and points the data store at
    /// the proxy's current port.
    func ready(for url: URL?) async throws {
        let loopbackPort = url.flatMap(Self.loopbackPort(of:))
        let port = try await prepare(loopbackPort)
        if port != appliedProxyPort, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) {
            dataStore.proxyConfigurations = [
                ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: nwPort)),
            ]
            appliedProxyPort = port
            // A new proxy port means a new connection: loopback forwards too.
            readiedLoopbackPorts.removeAll()
        }
        if let loopbackPort { readiedLoopbackPorts.insert(loopbackPort) }
    }

    /// Whether a navigation to `url` needs `ready(for:)` first: a loopback
    /// port this route has not mirrored yet.
    func needsReady(for url: URL) -> Bool {
        guard let port = Self.loopbackPort(of: url) else { return false }
        return !readiedLoopbackPorts.contains(port)
    }

    /// The port of an `http(s)` URL addressed to loopback (`localhost`,
    /// `127.0.0.0/8`, `::1`, `0.0.0.0`), which the system connects to
    /// directly instead of through the proxy.
    static func loopbackPort(of url: URL) -> Int? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let isLoopback = host == "localhost" || host == "::1" || host == "0.0.0.0"
            || (octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil })
        guard isLoopback else { return nil }
        return url.port ?? (scheme == "https" ? 443 : 80)
    }
}
#endif
