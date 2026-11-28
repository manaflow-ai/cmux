public import CmuxNextRemoteView
public import Foundation

#if DEBUG
/// The record URL of a development remote tab:
/// `cmux://remote-browser?address=127.0.0.1:4103[&url=<first page>][&secret_file=<path>]`. The
/// tab survives relaunch like any browser record and reconnects to the same
/// loopback host. Phase 1 hosts listen on loopback only
/// (`RemoteRdLoopbackEndpoint`), so the address is a port on 127.0.0.1.
/// `secret_file` names the private file with the host's secret
/// (`RemoteBrowserSecretFile`); the record never holds the secret itself.
/// `machine` (cx-2cob slice 2) puts the loopback address on that machine:
/// the app reaches it over the machine's daemon link (`loopback-forward-v1`).
public nonisolated struct RemoteBrowserTabRecord: Sendable, Hashable {
    public static let scheme = "cmux"
    public static let urlHost = "remote-browser"

    public let endpoint: RemoteRdLoopbackEndpoint
    /// The page the tab loads first (http or https), if any.
    public let initialURL: URL?
    /// The absolute path of the host's secret file, if the tab names one.
    public let secretFile: String?
    /// The machine whose loopback has the host; nil: this Mac.
    public let machine: String?

    /// `secretFile` is an absolute path (a record's own `secretFile`).
    public init(endpoint: RemoteRdLoopbackEndpoint, initialURL: URL? = nil, secretFile: String? = nil, machine: String? = nil) {
        self.endpoint = endpoint
        self.initialURL = initialURL
        self.secretFile = secretFile
        self.machine = machine.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Accepts `PORT`, `127.0.0.1:PORT` and `localhost:PORT` (whitespace
    /// trimmed); nil for any other host or a privileged port, or for a
    /// `secretFile` that is not an absolute path after `~` expansion.
    public init?(address: String, initialURL: URL? = nil, secretFile: String? = nil, machine: String? = nil) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        let portText: Substring
        switch parts.count {
        case 1: portText = parts[0]
        case 2 where ["127.0.0.1", "localhost"].contains(parts[0].lowercased()): portText = parts[1]
        default: return nil
        }
        guard let port = UInt16(portText), let endpoint = RemoteRdLoopbackEndpoint(port: port) else { return nil }
        let file = secretFile.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let path = file.map { RemoteBrowserSecretFile(path: $0).path }
        if let path, !path.hasPrefix("/") { return nil }
        self.endpoint = endpoint
        self.initialURL = initialURL
        self.secretFile = path
        self.machine = machine.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init?(url: URL) {
        guard Self.matches(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let address = items.first(where: { $0.name == "address" })?.value else { return nil }
        let first = items.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:))
        self.init(address: address, initialURL: first.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
                  secretFile: items.first(where: { $0.name == "secret_file" })?.value,
                  machine: items.first(where: { $0.name == "machine" })?.value)
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
            + (secretFile.map { [URLQueryItem(name: "secret_file", value: $0)] } ?? [])
            + (machine.map { [URLQueryItem(name: "machine", value: $0)] } ?? [])
        // Every part is a plain host, port or percent-encoded query.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
#endif
