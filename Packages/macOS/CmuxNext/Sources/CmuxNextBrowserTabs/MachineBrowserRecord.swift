public import Foundation

/// The record of a browser tab whose page runs on another machine (cx-2cob,
/// Lawrence 2026-10-09: a browser in a machine's workspace runs on that
/// machine): `cmux://remote-browser?machine=<id>[&url=<first page>]`. It
/// names the machine, never an address or a secret; cmux finds the
/// machine's browser host over its own authenticated link (slice 2). The
/// development loopback record (`?address=`) is a different record.
public nonisolated struct MachineBrowserRecord: Hashable, Sendable {
    public static let scheme = "cmux"
    public static let urlHost = "remote-browser"

    public let machine: String
    /// The page to open first (http or https only).
    public let initialURL: URL?

    public init(machine: String, initialURL: URL?) {
        self.machine = machine
        self.initialURL = initialURL.flatMap(Self.webPage)
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host()?.lowercased() == Self.urlHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.contains(where: { $0.name == "address" }),
              let machine = items.first(where: { $0.name == "machine" })?.value, !machine.isEmpty else { return nil }
        self.init(machine: machine, initialURL: items.first { $0.name == "url" }?.value.flatMap(URL.init(string:)))
    }

    public static func matches(_ url: URL?) -> Bool { url.flatMap(Self.init(url:)) != nil }

    /// The record in `text` (a tab's record URL) when it names `machine`,
    /// the machine whose tree holds the tab. A machine's tree can never make
    /// this Mac open a browser on another machine.
    public static func owned(_ text: String?, byMachine machine: String) -> MachineBrowserRecord? {
        guard let record = text.flatMap(URL.init(string:)).flatMap(Self.init(url:)), record.machine == machine else { return nil }
        return record
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.urlHost
        components.queryItems = [URLQueryItem(name: "machine", value: machine)]
            + (initialURL.map { [URLQueryItem(name: "url", value: $0.absoluteString)] } ?? [])
        return components.url ?? URL(fileURLWithPath: "/")
    }

    private static func webPage(_ url: URL) -> URL? {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
    }
}
