import Foundation

/// The record of a browser tab whose page runs on another machine (cx-2cob,
/// Lawrence 2026-10-09: a browser in a machine's workspace runs on that
/// machine): `cmux://remote-browser?machine=<id>[&url=<first page>]`. It
/// names the machine, never an address or a secret; cmux finds the
/// machine's browser host over its own authenticated link (slice 2). The
/// development loopback record (`?address=`) is a different record.
nonisolated struct MachineBrowserRecord: Hashable, Sendable {
    static let scheme = "cmux"
    static let urlHost = "remote-browser"

    let machine: String
    /// The page to open first (http or https only).
    let initialURL: URL?

    init(machine: String, initialURL: URL?) {
        self.machine = machine
        self.initialURL = initialURL.flatMap(Self.webPage)
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host()?.lowercased() == Self.urlHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.contains(where: { $0.name == "address" }),
              let machine = items.first(where: { $0.name == "machine" })?.value, !machine.isEmpty else { return nil }
        self.init(machine: machine, initialURL: items.first { $0.name == "url" }?.value.flatMap(URL.init(string:)))
    }

    static func matches(_ url: URL?) -> Bool { url.flatMap(Self.init(url:)) != nil }

    /// The record in `text` (a tab's record URL) when it names `machine`,
    /// the machine whose tree holds the tab. A machine's tree can never make
    /// this Mac open a browser on another machine.
    static func owned(_ text: String?, byMachine machine: String) -> MachineBrowserRecord? {
        guard let record = text.flatMap(URL.init(string:)).flatMap(Self.init(url:)), record.machine == machine else { return nil }
        return record
    }

    var url: URL {
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

/// Where a new browser tab of a pane runs (cx-2cob design, decided
/// 2026-10-09): this Mac for this Mac's panes; the pane's machine for
/// another machine's panes while that machine's browser host is available
/// (a cached check, never a wait on the key press). Otherwise this Mac's
/// tab, which says so with the This Mac omnibar chip; the chip's menu
/// offers Open on <machine>.
nonisolated enum BrowserPlacement: Equatable, Sendable {
    case local
    case machine(String)

    static func resolve(isLocal: Bool, machine: String, hostAvailable: Bool) -> BrowserPlacement {
        isLocal || !hostAvailable ? .local : .machine(machine)
    }

    /// The address a new tab opens: on a machine, its record with `url` as
    /// the first page. A local file or a Chromium internal page is this
    /// Mac's own and stays as it is.
    func address(for url: URL?) -> URL? {
        guard case let .machine(machine) = self else { return url }
        if let url, !["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        return MachineBrowserRecord(machine: machine, initialURL: url).url
    }
}

/// Why a machine browser tab shows no page yet (the design's not-ready
/// states). Slice 1 has no browser host on any machine.
nonisolated enum MachineBrowserState: Equatable, Sendable {
    case ready
    /// The machine has no browser host (an SSH machine: slice 2 installs it).
    case notInstalled(String)
    /// The machine's platform has no browser host yet (Cloud machines run Linux).
    case unavailable(String)
    case notConnected(String)

    static func resolve(name: String, isCloud: Bool, connected: Bool, hostReady: Bool) -> MachineBrowserState {
        guard connected else { return .notConnected(name) }
        if hostReady { return .ready }
        return isCloud ? .unavailable(name) : .notInstalled(name)
    }

    var message: String {
        switch self {
        case .ready: ""
        case let .notInstalled(name): MachineBrowserStrings.notInstalled(name)
        case let .unavailable(name): MachineBrowserStrings.unavailable(name)
        case let .notConnected(name): MachineBrowserStrings.notConnected(name)
        }
    }
}
