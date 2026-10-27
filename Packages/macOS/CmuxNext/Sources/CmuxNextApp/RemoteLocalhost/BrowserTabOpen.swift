import CmuxNextBrowser
import typealias CmuxNextDaemon.SurfaceID
import CmuxNextPages
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import CmuxNextSettings
import CryptoKit
import Foundation

/// `browser.tab.open` (a host action of the Cloud page, through
/// `cmux.app.action.run`): a Chromium tab whose store sends every request,
/// loopback included, to a Cloud machine's local proxy, so the tab reaches
/// that machine's localhost and never this Mac's.
///
/// Args: `{url, machineStore: {machine, machineName, proxy: {kind: "http",
/// host: "127.0.0.1", port, username, password}}, incarnation, generation, engine: "cef"}` (the proxy is the answer of
/// `cloud.browser.open`). Every refusal is typed; nothing falls back to
/// WebKit or to an unproxied tab.
enum BrowserTabOpen {
    static let action = "browser.tab.open"
    /// The only page that may hand over a proxy (the Cloud page in the app).
    static let callerPage = PageDescriptor.cloud.id
    /// The store key is `machineKey(machine:)`: 16 lowercase hex digits of
    /// SHA-256 over this prefix and the machine id. The prefix keeps it apart
    /// from remote-localhost keys (SHA-256 of a daemon `registry_id`).
    static let machineKeyPrefix = "cmux.cloud.browser-store.v1:"

    enum Refusal: Error, Equatable {
        /// A machine store opens only in Chromium (`engine: "cef"`).
        case proxyRequiresCEF
        /// The machine store or proxy is missing or not the local HTTP proxy on 127.0.0.1.
        case proxyInvalid
        /// The caller may not hand over a proxy (only the Cloud page may).
        case proxyOriginRefused
        /// Chromium is not available, or failed to make the tab.
        case cefUnavailable
        /// The URL is not an http(s) loopback URL.
        case invalidURL
        /// No window to open the tab in.
        case noWindow

        var code: String {
            switch self {
            case .proxyRequiresCEF: "cmux.browser.proxy_requires_cef"
            case .proxyInvalid: "cmux.browser.proxy_invalid"
            case .proxyOriginRefused: "cmux.browser.proxy_origin_refused"
            case .cefUnavailable: "cmux.browser.cef_unavailable"
            case .invalidURL: "cmux.browser.invalid_url"
            case .noWindow: "cmux.browser.no_window"
            }
        }

        var pageError: PageError { PageError(code: code, message: code) }
    }

    struct Request: Equatable {
        var url: URL
        var machine: String
        var machineName: String
        var incarnation: UInt64
        var generation: UInt64
        var proxyPort: UInt16
        var credential: ProxyCredential
    }

    static func machineKey(machine: String) -> String {
        SHA256.hash(data: Data((machineKeyPrefix + machine).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks `args` from page `page` (set by the page host, never by the page).
    static func request(args: JSONValue, page: String) throws(Refusal) -> Request {
        guard page == callerPage else { throw .proxyOriginRefused }
        return try checked(args)
    }

    /// `cmux cloud open-browser` (CloudHandlers+Browser.swift): `route` is the `cloud.browser.open`
    /// answer the app asked for itself, so no page hands it over and the caller page check does not
    /// apply. The route gets every other check of a page's request.
    static func request(route: JSONValue, machineName: String) throws(Refusal) -> Request {
        try checked(.object([
            "engine": .string("cef"), "url": route["url"] ?? .null,
            "incarnation": route["incarnation"] ?? .null, "generation": route["generation"] ?? .null,
            "machineStore": .object(["machine": route["machine"] ?? .null, "machineName": .string(machineName), "proxy": route["proxy"] ?? .null]),
        ]))
    }

    private static func checked(_ args: JSONValue) throws(Refusal) -> Request {
        guard args["engine"]?.stringValue == "cef" else { throw .proxyRequiresCEF }
        guard let text = args["url"]?.stringValue, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              LoopbackHost(url: url)?.isLoopback == true else { throw .invalidURL }
        guard let store = args["machineStore"], let machine = store["machine"]?.stringValue, !machine.isEmpty,
              let proxy = store["proxy"], proxy["kind"]?.stringValue == "http", proxy["host"]?.stringValue == "127.0.0.1",
              case .number(let number)? = proxy["port"], number.rounded() == number, number >= 1, number <= 65535,
              let username = proxy["username"]?.stringValue, !username.isEmpty, username.utf8.count <= 128,
              let password = proxy["password"]?.stringValue, password.utf8.count >= 32, password.utf8.count <= 256,
              case .number(let incarnation)? = args["incarnation"], incarnation.rounded() == incarnation,
              incarnation >= 1, incarnation <= 9_007_199_254_740_991,
              case .number(let generation)? = args["generation"], generation.rounded() == generation,
              generation >= 1, generation <= 9_007_199_254_740_991
        else { throw .proxyInvalid }
        let name = store["machineName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? machine
        return Request(
            url: url,
            machine: machine,
            machineName: name,
            incarnation: UInt64(incarnation),
            generation: UInt64(generation),
            proxyPort: UInt16(number),
            credential: ProxyCredential(username: username, password: password)
        )
    }
}

extension BrowserTabOpen {
    /// The page host's entry (`cmux.app.action.run`): `page` is the calling
    /// page's id as the host knows it. A refusal is a typed `PageError`.
    @MainActor
    static func run(args: JSONValue, page: String, services: AppServices) async throws(PageError) -> JSONValue {
        do {
            try await open(request(args: args, page: page), services: services)
            return ["opened": .bool(true)]
        } catch {
            throw error.pageError
        }
    }

    /// Opens a checked request in the active window's focused pane: the
    /// Chromium page is made first (with its store), then the daemon tab
    /// adopts it. Throws a typed refusal; never opens the URL any other way.
    /// `background` leaves the pane's selected tab as it is (a CLI run without
    /// focus); `then` gets the new tab's surface once the daemon made it.
    /// `reportsRefusal` answers the pane's refusal (browser off, machine not
    /// connected) instead of showing it; nil when the tab was asked for.
    @MainActor @discardableResult
    static func open(_ request: Request, services: AppServices, background: Bool = false, reportsRefusal: Bool = false,
                     then: (@MainActor (SurfaceID) -> Void)? = nil) async throws(Refusal) -> String? {
        guard case let browserTabs = services.cache.browserTabs, browserTabs.cefUnavailable() == nil else { throw .cefUnavailable }
        guard let pane = services.windows.active?.focusedPane else { throw .noWindow }
        let store: BrowserMachineStore
        do {
            store = try await services.remoteLocalhost.cloudBrowserStore(
                machineKey: machineKey(machine: request.machine),
                machineName: request.machineName,
                incarnation: request.incarnation,
                generation: request.generation,
                proxyPort: request.proxyPort,
                proxyUsername: request.credential.username,
                proxyPassword: request.credential.password,
                refetch: refetch(machine: request.machine, name: request.machineName, services: services)
            )
        } catch {
            throw .proxyInvalid
        }
        let configuration = BrowserTabConfiguration(
            initialURL: request.url,
            machineStore: store,
            navigationGuard: .loopbackOnly
        )
        let page: any BrowserTab
        do {
            page = try await services.cache.makeCEFTab(configuration)
        } catch {
            throw .cefUnavailable
        }
        // The daemon tab adopts the page (TabContentCache.install records
        // its tab id). The record starts blank: a page made from the record
        // before the adoption lands must not load the URL unproxied.
        services.cache.pageRequests.proxiedTabs.expect(store, machine: .init(id: request.machine, name: request.machineName))
        let open = { pane.newBrowserTab(url: nil, engine: BrowserEngineTag.cef.rawValue, adopting: page, background: background, then: then) }
        guard reportsRefusal else {
            open()
            return nil
        }
        var opened = false
        let refusal = services.registry.reportingRefusal { opened = open() }
        return opened ? nil : refusal ?? RefusalStrings.chromiumUnavailable
    }
}

extension BrowserTabOpen {
    /// Asks the Cloud app server for `machine`'s browser route again (#25595): ``CloudBrowserRoute``
    /// calls it when the route a tab had is gone (the link dropped or was replaced) and on the first
    /// request of a tab restored after a relaunch. Only for a machine on the app server's link that
    /// runs: `cloud.browser.open` connects the link, which would start a paused machine, and a page
    /// must never do that. Each answer gets the checks of a page's request, for this machine.
    static func refetch(machine: String, name: String, services: AppServices) -> CloudBrowserRoute.Fetch {
        let ops = services.cloud.appOps
        return { [weak services] host, port in
            guard let services, await isRunning(machine, services: services) else {
                throw LoopbackTunnelFailure.unavailable("\(name) is not running")
            }
            let route = try await ops("cloud.browser.open", .object(["machine": .string(machine), "port": .number(Double(port)), "host": .string(host)]),
                                      UUID().uuidString.lowercased(), .script)
            let request = try await request(route: pageJSON(route), machineName: name)
            guard request.machine == machine else { throw Refusal.proxyInvalid }
            return CloudBrowserRoute.Answer(proxyPort: request.proxyPort, credential: request.credential)
        }
    }

    private static func isRunning(_ machine: String, services: AppServices) -> Bool {
        services.machines.cloud.contains { session in
            guard session.machineID == machine, session.appLink != nil else { return false }
            let connected = if case .connected = session.daemon.store.connectionState { true } else { false }
            return mayRefetch(live: session.machine.status.isLive, connected: connected)
        }
    }

    /// Whether a page may ask for its machine's route: the machine's record says it runs, or its
    /// daemon is connected (a click resumed it and the record still reads paused until the next
    /// list). Neither: the machine is paused or gone, and asking would start it.
    nonisolated static func mayRefetch(live: Bool, connected: Bool) -> Bool { live || connected }

    /// The store of a proxied tab restored after a relaunch (``ProxiedBrowserTabs/restore``): its
    /// machine's route is fetched on the page's first request, once the machine is listed, linked
    /// and running; until then the page shows the proxy's "not connected" page, which loads again
    /// when the machine connects (``StrandedPageReload``). Never this Mac's localhost.
    static func restoredStore(_ machine: ProxiedBrowserTabs.Machine, services: AppServices) async -> BrowserMachineStore? {
        try? await services.remoteLocalhost.restoredCloudBrowserStore(
            machineKey: machineKey(machine: machine.id), machineName: machine.name,
            fetch: refetch(machine: machine.id, name: machine.name, services: services))
    }
}
