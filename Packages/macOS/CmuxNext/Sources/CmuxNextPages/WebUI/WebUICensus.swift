#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
public import CmuxNextSettings
public import WebKit

/// `debug.webui` (plans/cmux-next/chrome-parity/p13-webui.md task 001, section 3.G): one row per
/// cmux page, spare and Chromium helper process, so a bench can name every renderer at Home and see
/// what reaches a hidden page. Chrome's task manager answers the same question from
/// `TaskManagerInterface` (chrome/browser/task_manager/task_manager_interface.h): one row per
/// process with the tabs, extensions and spare renderers it hosts. DEBUG and bench builds only.
///
/// The census is a value read on the main actor (``init(pages:registry:newTabSpare:spareWindows:browserTabs:rendererProcess:webKitPID:retiring:engineCloses:)``);
/// the helper list is read off it and joined in ``report(listing:)``.
///
/// JSON keys of the reply:
/// - `pages`: one object per live ``PageWebView``, oldest first:
///   - `page` (string): the descriptor id. `instance` (number): ``PageRegistry/instance(of:)``.
///   - `engine`: `chromium` or `webkit`. `group`: the descriptor's ``PageProcessGroup`` (`agent`, `privileged`,
///     `viewer`, `solo`, `secrets`); Chromium shares renderers by it only with the `pageProcessGroups` feature.
///   - `state`: `visible` or `hidden` to the person: hidden when the host told the engine so or
///     when the page is a parked spare (Chrome counts no spare renderer as visible).
///     `engine_visible` (bool): what the host last told the engine (true for a spare parked in a
///     window). `hidden_for_s`: seconds since it was hidden, null while visible.
///   - `keep_reasons` (strings): the reasons the host sees now, of `visible` (never a spare's),
///     `loading`, `focused`.
///   - `spare`: `new_tab` (the parked New Tab page), `page_preload` (a page in the preload slot's parking) or null.
///   - `pooled` (bool): opened parked for the preload slot. `window_number`: null in no window.
///   - `browser_id`: the Chromium browser id, null on WebKit.
///   - `renderer_clients`, `renderer_pids`: the renderer client ids of the page's frames and the
///     helper pids that run them (Chromium).
///   - `webkit_pid`: the WebContent pid (`_webProcessIdentifier`, when WebKit has it) of a WebKit page, else null.
///   - `deliveries_while_hidden`: router events delivered while hidden. `pushes_while_hidden`:
///     native script pushes (theme, glass, document attributes) while hidden. Both count from the
///     page's start or the last `reset`. `reloads`: the host's reloads after a crash (a page that
///     crashed hidden reloads when it shows, ``PageCrashRecovery``). `script_deliveries`, `data_deliveries`: runs of
///     router envelopes sent as scripts and as data on the page push channel (`pagePushChannel`), since the start.
/// - `spares`: spares that are no page view, each `{spare, state, renderer_clients, renderer_pids,
///   webkit_pid}`: `cef_window` and `cef_pages_window`, the Chromium spare windows of the default
///   and the cmux pages profile (each `state` is `none`, `creating`, `live`, `taken` or `closed`;
///   its renderer is its about:blank placeholder's), and `new_tab`, a New Tab spare with no page
///   view (`state` null, its `webkit_pid`).
/// - `browser_tabs`: `{tab, renderer_clients, renderer_pids}` per Chromium browser tab.
/// - `processes`: one per Chromium helper process: `{pid, kind, renderer_client_id, hosts}`. `kind`
///   is `renderer`, `extension_renderer`, `gpu`, `network`, `utility` or `other`;
///   `renderer_client_id` is null but for `renderer`; `hosts` names what the renderer runs
///   (`page:<id>#<instance>`, `spare:cef_window`, `spare:cef_pages_window`, `browser_tab:<id>`), empty when nothing known does.
/// - `retire`: `pending`, the closed pages whose engine page waits for the retirer's deadline;
///   `engine_closes`, the engine page closes of the host's pages since launch; `engine_closes_in_close_turn`,
///   those that ran inside ``WebUIHost/close(_:)`` (0: a close asks no engine page to end in its turn);
///   `engine_close_uptimes`, the system uptime in seconds (the clock of `debug.action_budget`) of the last 32,
///   oldest first.
nonisolated public struct WebUICensus: Sendable {
    /// The engine page closes of a ``WebUIHost``'s pages (``WebUIHost/engineCloses``).
    nonisolated public struct EngineCloses: Sendable, Equatable {
        /// How many times ``uptimes`` keeps.
        public static let keptUptimes = 32
        public private(set) var total = 0
        /// The closes that ran inside the host's ``WebUIHost/close(_:)``, in the close's turn.
        public private(set) var inCloseTurn = 0
        /// When the last ``keptUptimes`` ran (system uptime, s), oldest first.
        public private(set) var uptimes: [Double] = []

        public init() {}

        mutating func record(at uptime: Double, inCloseTurn closing: Bool) {
            total += 1
            if closing { inCloseTurn += 1 }
            uptimes.append(uptime)
            if uptimes.count > Self.keptUptimes { uptimes.removeFirst(uptimes.count - Self.keptUptimes) }
        }
    }

    /// One Chromium helper process.
    nonisolated public struct Helper: Sendable, Equatable {
        public var pid: Int32
        /// `renderer`, `extension_renderer`, `gpu`, `network`, `utility` or `other`.
        public var kind: String
        /// The `--renderer-client-id` of a tab renderer; nil for any other kind.
        public var rendererClientID: Int32?

        public init(pid: Int32, kind: String, rendererClientID: Int32?) {
            self.pid = pid
            self.kind = kind
            self.rendererClientID = rendererClientID
        }
    }

    /// A renderer host that is no page view: the Chromium spare window or a browser tab.
    nonisolated public struct Host: Sendable, Equatable {
        /// `cef_window` or `new_tab` for a spare, the tab id for a browser tab.
        public var name: String
        /// The spare window's state; nil for a browser tab.
        public var state: String?
        public var rendererClients: [Int32]
        /// The WebContent pid of a WebKit spare.
        public var webKitPID: Int32?

        public init(name: String, state: String? = nil, rendererClients: [Int32] = [], webKitPID: Int32? = nil) {
            self.name = name
            self.state = state
            self.rendererClients = rendererClients
            self.webKitPID = webKitPID
        }
    }

    /// One page view's row.
    nonisolated public struct Page: Sendable, Equatable {
        public var page: String
        /// The descriptor's capability group.
        public var group: PageProcessGroup
        public var instance: UInt64
        public var census: PageWebView.Census
        public var keepReasons: [String]
        public var spare: String?
        public var windowNumber: Int?
        public var browserID: Int32?
        public var rendererClients: [Int32]
        public var webKitPID: Int32?
        /// Runs of router envelopes sent as scripts, and as data on the page push channel.
        public var scriptDeliveries = 0
        public var dataDeliveries = 0

        /// The name the `processes` rows use for this page.
        var hostName: String { "page:\(page)#\(instance)" }
    }

    public private(set) var pages: [Page]
    public private(set) var spares: [Host]
    public private(set) var browserTabs: [Host]
    /// The host's closed pages still waiting for their engine close.
    public private(set) var retiring: Int
    public private(set) var engineCloses: EngineCloses

    /// Reads every page and spare now.
    ///
    /// - Parameters:
    ///   - pages: The live page views (``WebUIHost/registry``'s ``PageRegistry/pages(id:)``).
    ///   - registry: Their registry, for each page's instance number.
    ///   - newTabSpare: The page view of the parked New Tab page, if one is parked, in either engine.
    ///   - spareWindows: The Chromium spare windows, one per kind; empty without Chromium.
    ///   - browserTabs: The Chromium browser tabs, with their renderer clients.
    ///   - rendererProcess: A Chromium page's browser id and renderer client ids.
    ///   - webKitPID: A WebKit view's WebContent pid, nil when WebKit does not say.
    ///   - retiring: The host's ``PageRetirer/count``.
    ///   - engineCloses: The host's ``WebUIHost/engineCloses``.
    @MainActor
    public init(pages: [PageWebView], registry: PageRegistry, newTabSpare: PageWebView?, spareWindows: [Host],
                browserTabs: [Host], rendererProcess: @MainActor (any PageChromiumPage) -> (browserID: Int32?, clients: [Int32]),
                webKitPID: @MainActor (WKWebView) -> Int32?, retiring: Int = 0, engineCloses: EngineCloses = EngineCloses()) {
        self.retiring = retiring
        self.engineCloses = engineCloses
        var newTabSpareSeen = false
        self.pages = pages.map { view in
            let census = view.census
            let process = view.chromiumPage.map { rendererProcess($0) }
            let isNewTabSpare = view === newTabSpare
            newTabSpareSeen = newTabSpareSeen || isNewTabSpare
            let spare: String? = isNewTabSpare ? "new_tab" : census.parked ? "page_preload" : nil
            var keepReasons: [String] = []
            if !census.hidden, spare == nil { keepReasons.append("visible") }
            if census.loading { keepReasons.append("loading") }
            if let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view) {
                keepReasons.append("focused")
            }
            return Page(page: view.pageID, group: view.descriptor.processGroup, instance: registry.instance(of: view), census: census, keepReasons: keepReasons,
                        spare: spare,
                        windowNumber: view.window?.windowNumber, browserID: process?.browserID,
                        rendererClients: process?.clients ?? [],
                        webKitPID: census.engine == "webkit" ? view.webKitEngine.flatMap { webKitPID($0) } : nil,
                        scriptDeliveries: view.scriptTarget.scriptDeliveries, dataDeliveries: view.scriptTarget.dataDeliveries)
        }
        var spares = spareWindows
        if let newTabSpare, !newTabSpareSeen {
            spares.append(Host(name: "new_tab", webKitPID: newTabSpare.webKitEngine.flatMap { webKitPID($0) }))
        }
        self.spares = spares
        self.browserTabs = browserTabs
    }

    /// Lists the helpers with `list` off the main actor (it reads each new child process's argv),
    /// then builds the reply.
    @concurrent
    public func report(listing list: @Sendable () -> [Helper]) async -> JSONValue {
        report(helpers: list())
    }

    /// The reply (the keys in this type's documentation), with `helpers` as the app's Chromium helpers.
    public func report(helpers: [Helper]) -> JSONValue {
        var pidOfClient: [Int32: Int32] = [:]
        for helper in helpers {
            if let client = helper.rendererClientID { pidOfClient[client] = helper.pid }
        }
        var hostsOfClient: [Int32: [String]] = [:]
        func attribute(_ clients: [Int32], to name: String) {
            for client in clients { hostsOfClient[client, default: []].append(name) }
        }
        for page in pages { attribute(page.rendererClients, to: page.hostName) }
        for spare in spares { attribute(spare.rendererClients, to: "spare:\(spare.name)") }
        for tab in browserTabs { attribute(tab.rendererClients, to: "browser_tab:\(tab.name)") }

        func numbers<T: BinaryInteger>(_ values: [T]) -> JSONValue { .array(values.map { .number(Double($0)) }) }
        func number<T: BinaryInteger>(_ value: T?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
        func pids(_ clients: [Int32]) -> JSONValue { numbers(clients.compactMap { pidOfClient[$0] }) }

        let pageRows: [JSONValue] = pages.map { page -> JSONValue in
            [
                "page": .string(page.page), "instance": number(page.instance), "engine": .string(page.census.engine),
                "group": .string(page.group.rawValue), "state": .string(page.census.hidden ? "hidden" : "visible"),
                "engine_visible": .bool(page.census.engineVisible),
                "hidden_for_s": page.census.hiddenForSeconds.map { .number($0) } ?? .null,
                "keep_reasons": .array(page.keepReasons.map { .string($0) }),
                "spare": page.spare.map { .string($0) } ?? .null, "pooled": .bool(page.census.pooled),
                "window_number": number(page.windowNumber), "browser_id": number(page.browserID),
                "renderer_clients": numbers(page.rendererClients), "renderer_pids": pids(page.rendererClients),
                "webkit_pid": number(page.webKitPID),
                "deliveries_while_hidden": number(page.census.deliveriesWhileHidden),
                "pushes_while_hidden": number(page.census.pushesWhileHidden), "reloads": number(page.census.crashReloads),
                "script_deliveries": number(page.scriptDeliveries), "data_deliveries": number(page.dataDeliveries),
            ]
        }
        let spareRows: [JSONValue] = spares.map { spare -> JSONValue in
            ["spare": .string(spare.name), "state": spare.state.map { .string($0) } ?? .null,
             "renderer_clients": numbers(spare.rendererClients), "renderer_pids": pids(spare.rendererClients),
             "webkit_pid": number(spare.webKitPID)]
        }
        let tabRows: [JSONValue] = browserTabs.map { tab -> JSONValue in
            ["tab": .string(tab.name), "renderer_clients": numbers(tab.rendererClients), "renderer_pids": pids(tab.rendererClients)]
        }
        let processRows: [JSONValue] = helpers.map { helper -> JSONValue in
            let hosts: [String] = helper.rendererClientID.flatMap { hostsOfClient[$0] } ?? []
            return [
                "pid": number(helper.pid), "kind": .string(helper.kind), "renderer_client_id": number(helper.rendererClientID),
                "hosts": .array(hosts.map { JSONValue.string($0) }),
            ]
        }
        let retire: JSONValue = [
            "pending": number(retiring), "engine_closes": number(engineCloses.total),
            "engine_closes_in_close_turn": number(engineCloses.inCloseTurn),
            "engine_close_uptimes": .array(engineCloses.uptimes.map { .number($0) }),
        ]
        return ["pages": .array(pageRows), "spares": .array(spareRows), "browser_tabs": .array(tabRows),
                "processes": .array(processRows), "retire": retire]
    }
}

/// What a ``PageWebView`` keeps for its census row (PageWebView+Debug.swift).
struct PageCensusState {
    /// The visibility the host last gave the engine.
    var engineVisible = false
    /// In a spare's parking view (``PageWebView/noteCensusParked(_:in:)``).
    var parked = false
    /// When the page was last hidden; nil while it shows.
    var hiddenSince: Date?
    /// Native pushes (``PageNativePushes``) while hidden: one integer add each.
    var pushesWhileHidden = 0
    /// Tells the page's host that ``PageWebView/closeEngine()`` ran (``WebUIHost/engineCloses``).
    var engineClosed: (@MainActor () -> Void)?
}
#endif
