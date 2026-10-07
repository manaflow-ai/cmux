public import CmuxNextRemoteView
public import Foundation

#if DEBUG
/// The record URL of a development remote tab:
/// `cmux://remote-browser?address=127.0.0.1:4103[&url=<first page>]`. The
/// tab survives relaunch like any browser record and reconnects to the same
/// loopback host. Phase 1 hosts listen on loopback only
/// (`RemoteRdLoopbackEndpoint`), so the address is a port on 127.0.0.1.
public nonisolated struct RemoteBrowserTabRecord: Sendable, Hashable {
    public static let scheme = "cmux"
    public static let urlHost = "remote-browser"

    public let endpoint: RemoteRdLoopbackEndpoint
    /// The page the tab loads first (http or https), if any.
    public let initialURL: URL?

    public init(endpoint: RemoteRdLoopbackEndpoint, initialURL: URL? = nil) {
        self.endpoint = endpoint
        self.initialURL = initialURL
    }

    /// Accepts `PORT`, `127.0.0.1:PORT` and `localhost:PORT` (whitespace
    /// trimmed); nil for any other host or a privileged port.
    public init?(address: String, initialURL: URL? = nil) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let portText: Substring
        switch parts.count {
        case 1: portText = parts[0]
        case 2 where ["127.0.0.1", "localhost"].contains(parts[0].lowercased()): portText = parts[1]
        default: return nil
        }
        guard let port = UInt16(portText), let endpoint = RemoteRdLoopbackEndpoint(port: port) else { return nil }
        self.init(endpoint: endpoint, initialURL: initialURL)
    }

    public init?(url: URL) {
        guard Self.matches(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "address" })?.value else { return nil }
        let first = items.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:))
        self.init(address: address, initialURL: first.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil })
    }

    public static func matches(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme && url?.host()?.lowercased() == urlHost
    }

    public var address: String { "127.0.0.1:\(endpoint.port)" }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.urlHost
        components.queryItems = [URLQueryItem(name: "address", value: address)]
            + (initialURL.map { [URLQueryItem(name: "url", value: $0.absoluteString)] } ?? [])
        // Every part is a plain host, port or percent-encoded query.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
#endif
