import CmuxNextBrowser
import typealias CmuxNextDaemon.SurfaceID
import CmuxNextPages
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import CmuxNextSettings
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
    typealias Refusal = CloudBrowserRequest.Refusal
    typealias Request = CloudBrowserRequest
    static let machineKeyPrefix = CloudBrowserRequest.machineKeyPrefix

    static func machineKey(machine: String) -> String { CloudBrowserRequest.machineKey(machine: machine) }

    /// The calling page id comes from the page host, never the request.
    static func request(args: JSONValue, page: String) throws(Refusal) -> Request {
        guard page == callerPage else { throw .proxyOriginRefused }
        return try Request.checked(args)
    }

    /// The app requested this route itself; only its payload needs validation.
    static func request(route: JSONValue, machineName: String) throws(Refusal) -> Request {
        try Request.route(route, machineName: machineName)
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
            throw PageError(code: error.code, message: error.code)
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
    /// request of a tab restored after a relaunch. Only for a machine with a connected daemon on
    /// the app server's link: `cloud.browser.open` connects the link, which would start a paused
    /// machine, and a page must never do that. Each answer gets the checks of a page's request,
    /// for this machine.
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

    /// Only a connected daemon permits a page to ask for its route. The machine record can still
    /// say running after idle pause, or paused after a click resumes it; neither is authoritative
    /// for a background request that must never start the VM.
    nonisolated static func mayRefetch(live _: Bool, connected: Bool) -> Bool { connected }

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
