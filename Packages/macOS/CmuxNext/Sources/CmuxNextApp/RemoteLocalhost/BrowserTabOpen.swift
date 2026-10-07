import CmuxNextBrowser
import CmuxNextPages
import CmuxNextRemoteLocalhost
import CmuxNextSettings
import CryptoKit
import Foundation

/// `browser.tab.open` (a host action of the Cloud page, through
/// `cmux.app.action.run`): a Chromium tab whose store sends every request,
/// loopback included, to a Cloud machine's local proxy, so the tab reaches
/// that machine's localhost and never this Mac's.
///
/// Args: `{url, machineStore: {machine, machineName, proxy: {kind: "http",
/// host: "127.0.0.1", port}}, engine: "cef"}` (the proxy is the answer of
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
        var configuration: BrowserTabConfiguration
    }

    static func machineKey(machine: String) -> String {
        SHA256.hash(data: Data((machineKeyPrefix + machine).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks `args` from page `page` (set by the page host, never by the page).
    static func request(args: JSONValue, page: String) throws(Refusal) -> Request {
        guard page == callerPage else { throw .proxyOriginRefused }
        guard args["engine"]?.stringValue == "cef" else { throw .proxyRequiresCEF }
        guard let text = args["url"]?.stringValue, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              LoopbackHost(url: url)?.isLoopback == true else { throw .invalidURL }
        guard let store = args["machineStore"], let machine = store["machine"]?.stringValue, !machine.isEmpty,
              let proxy = store["proxy"], proxy["kind"]?.stringValue == "http", proxy["host"]?.stringValue == "127.0.0.1",
              case .number(let number)? = proxy["port"], number.rounded() == number, number >= 1, number <= 65535
        else { throw .proxyInvalid }
        let name = store["machineName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? machine
        let configuration = BrowserTabConfiguration(
            initialURL: url,
            machineStore: BrowserMachineStore(machineKey: machineKey(machine: machine), machineName: name, proxyPort: UInt16(number)),
            navigationGuard: .loopbackOnly
        )
        return Request(url: url, configuration: configuration)
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
    @MainActor
    static func open(_ request: Request, services: AppServices) async throws(Refusal) {
        guard let browserTabs = services.cache.browserTabs, browserTabs.cefUnavailable() == nil else { throw .cefUnavailable }
        guard let pane = services.windows.active?.focusedPane else { throw .noWindow }
        let page: any BrowserTab
        do {
            page = try await services.cache.makeCEFTab(request.configuration)
        } catch {
            throw .cefUnavailable
        }
        guard let store = request.configuration.machineStore else { page.close(); throw .proxyInvalid }
        // The daemon tab adopts the page (TabContentCache.install records
        // its tab id). The record starts blank: a page made from the record
        // before the adoption lands must not load the URL unproxied.
        services.cache.pageRequests.proxiedTabs.expect(store)
        pane.newBrowserTab(url: nil, engine: BrowserEngineTag.cef.rawValue, adopting: page)
    }
}
