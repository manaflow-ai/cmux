import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextOracle
import CmuxNextPages
import CmuxNextResources
import CmuxNextSettings
import Foundation

// `debug.page` (DEBUG builds): the generic page verb for every React page
// (plans/cmux-next/react-pages.md), from the Settings lead's `debug.settings_web`.
// Params: `page` (id; nil: any page), `instance` (a number from `list` or `state`), `parked`
// (true: the pool's parked spare). Without `instance` the target is a page that is not the parked
// spare (its document has no routes, so probes of it saw a failed-read banner no visible page
// showed), the one in the key window first, else the newest. `action`:
// - `list`: every live page of the id: instance, parked, window number, claim outcome;
// - `state` (default): page id, URL fragment, language, visible text, control count, computed
//   html/body backgrounds (the one-backdrop check), `painted` (the document's first frame, with
//   `painted_uptime` in host systemUptime seconds and `painted_ms` on the page clock), `instance`,
//   `parked`, `window_number` and `claim` (how a pooled host took its last claim: `path`
//   acknowledged / refused / timedOut / loaded, `ms`), `in_flight` (the page's calls still
//   running: id, op, age_ms), `discarded` and `restore` (the last restore after a discard, host
//   uptime seconds: `started` in the show's turn, `covered` when the snapshot went over the page,
//   `painted` at the restored document's first frame; null before one);
// - `snapshot` (`path`, default /tmp/cmux-page-<id>.png): the page as WebKit rendered it;
// - `command` (`command`, `text`): a dispatcher command (`find`, `focusSearch`, `back`, `forward`,
//   `reset`) on the page's command stream, as the key dispatcher sends it;
// - `connected` (`value` bool): the owner link state on the page's connection stream;
// - `scrollers`: `data-scrollers` and every element that shows a scroller at rest under "Always"
//   (overflowing auto/scroll boxes with their overflow in pixels; SCROLLBARS-THIN audit);
// - `click` (`selector`, `context_menu`?): clicks (or right-clicks) the first element matching the CSS selector;
// - `scroll` (`selector`, `block`? start | center | end | nearest, default start): scrolls the first
//   matching element into view at once (every scroller that holds it): `{scrolled, top, height,
//   viewport}` once its box is in view; an error when nothing rendered matches or it is still out of view,
//   so a capture step fails instead of shooting the fold;
// - `hover` (`selector`): moves the mouse onto the first matching element (a capture slot's window
//   never activates, so no pointer reaches its pages): `{hovered, native, x, y}`;
// - `query` (`selector`): each matching element's data-* attributes, classes and text, in document order;
// - `type` (`text`, `selector`?): inserts text as typed input in the matching (else the focused) element;
// - `call` (`op`, `params`): one call message through the page's router, exactly as the page's
//   bridge sends it (the host sets the calling page's id). With `page: "cmux.cloud"` and no live
//   Cloud page, a hidden one is made first (so a probe needs no open Cloud tab).
// - `ping`: one host call the page answers `unknown_op`: `{ms}`, its round trip (`bench-webui.py push`,
//   p13-webui-079; `debug.webui` counts whether it went as data or a script);
// - `hangOnClick`: the page's next mousedown never returns, so its renderer hangs on input Chromium
//   waits for and the "Page unresponsive" card shows (scripts/cmux-next/page-hang-live.py --page).
// The control router's deadline bounds every action.
extension AppControl {
    func registerPageDebugMethods(_ services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        service?.router.register([
            .async("debug.page") { [weak services] call in await DebugPages.handle(call.params, services: services) },
            // Every page, spare and Chromium helper process: state, keep reasons, pids and what reached
            // hidden pages (keys in WebUICensus). `reset: true` zeroes the counters after
            // the read. The page walk runs in the automation work class, the helpers' argv off the main actor.
            .mainActor("debug.webui") { [weak services] call in
                guard let services, let census = AppControl.webUICensus(services, reset: call.params["reset"]?.boolValue == true) else { return .value(.null) }
                let parent = services.cache.chromium.helperParent
                return .followUp { await census.report { AppControl.webUIHelpers(of: parent) } }
            },
        ])
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The children of `parent` (the app, or the Chromium Host: `ChromiumEngineSlot.helperParent`) as `debug.webui`
    /// rows. Reads each new child's argv: off the main actor.
    nonisolated static func webUIHelpers(of parent: pid_t?) -> [WebUICensus.Helper] {
        ChromiumHelperProcess.list(parent: parent).map {
            WebUICensus.Helper(pid: $0.pid, kind: $0.kind.name, rendererClientID: $0.kind.rendererClientID)
        }
    }

    /// `debug.webui`'s main-actor half: every page, spare and Chromium browser tab now; `reset`
    /// zeroes the pages' while-hidden counters after the read.
    static func webUICensus(_ services: AppServices?, reset: Bool) -> WebUICensus? {
        guard let services else { return nil }
        let registry = services.webUI.registry, pages = registry.pages()
        let cef = services.cache.cef
        let census = WebUICensus(
            pages: pages, registry: registry, newTabSpare: services.newTabSpares.spare?.view.page,
            spareWindows: [
                WebUICensus.Host(name: "cef_window", state: cef.spareWindowState, rendererClients: cef.spareWindowRendererClients),
                WebUICensus.Host(name: "cef_pages_window", state: cef.pagesSpareWindowState, rendererClients: cef.pagesSpareWindowRendererClients),
            ],
            browserTabs: services.cache.browsers.sorted { $0.key < $1.key }.compactMap { id, entry in
                (entry.tab as? CEFTab).map { WebUICensus.Host(name: id, rendererClients: $0.rendererClientIDs) }
            },
            rendererProcess: { page in
                let tab = (page as? CEFPageChromiumPage)?.tab
                return (tab?.browserID, tab?.rendererClientIDs ?? [])
            },
            webKitPID: { WebContentProcess.identifier(of: $0) },
            retiring: services.webUI.retirer.count, engineCloses: services.webUI.engineCloses)
        if reset { pages.forEach { $0.resetCensusCounters() } }
        return census
    }
    #endif
}

#if DEBUG || CMUX_BENCH_HOOKS
enum DebugPages {
    /// Hidden pages `call` made (kept alive for later calls).
    @MainActor private static var made: [PageWebView] = []

    @MainActor
    static func handle(_ params: [String: JSONValue], services: AppServices?) async -> JSONValue {
        let id = params["page"]?.stringValue
        if params["action"]?.stringValue == "call", id == PageDescriptor.cloud.id, PageRegistry.pages(id: id).isEmpty,
           let services, let cloud = PageFactory(services: services).cloudWebPage() {
            made.append(cloud)
        }
        if params["action"]?.stringValue == "list" {
            return ["pages": .array(PageRegistry.pages(id: id).map { .object(identity($0)) })]
        }
        let instance = params["instance"]?.intValue.map { UInt64(max($0, 0)) }
        guard let page = PageRegistry.probeTarget(id: id, parked: params["parked"]?.boolValue == true,
                                                  instance: instance) else {
            return ["error": .string("no live page\(id.map { " " + $0 } ?? "")")]
        }
        switch params["action"]?.stringValue ?? "state" {
        case "state":
            var state = await page.debugState()
            if case .object(var members) = state {
                members.merge(identity(page)) { _, new in new }
                members["subscriptions"] = .number(Double(page.router.subscriptionCount))
                members["in_flight"] = .array(page.router.inFlightCalls())
                // The first frame of this document (preflights wait on it with a deadline).
                members["painted"] = .bool(page.hasPainted)
                members["painted_uptime"] = page.paintedUptime.map { .number($0) } ?? .null
                members["discarded"] = .bool(page.isDiscarded)
                members["restore"] = page.lastRestoreTimes.map { times -> JSONValue in
                    ["started": .number(times.started), "covered": times.covered.map { .number($0) } ?? .null,
                     "painted": times.painted.map { .number($0) } ?? .null]
                } ?? .null
                // Why a page may not paint: no window, a hidden view, or a window macOS reports
                // as occluded (WebKit stops rendering updates for an occluded window).
                members["in_window"] = .bool(page.window != nil)
                // visibility-walk-allow: debug.page reports the view's own AppKit hidden state, the fact a node cannot show
                members["view_hidden"] = .bool(page.isHiddenOrHasHiddenAncestor)
                members["window_visible"] = .bool(page.window?.isVisible ?? false)
                members["window_occluded"] = .bool(!(page.window?.occlusionState.contains(.visible) ?? false))
                members["frame"] = .string("\(Int(page.frame.width))x\(Int(page.frame.height))")
                state = .object(members)
            }
            return state
        case "snapshot":
            let path = params["path"]?.stringValue ?? "/tmp/cmux-page-\(page.pageID).png"
            let written = await page.debugSnapshot(to: URL(fileURLWithPath: path))
            return written ? ["path": .string(path)] : ["error": "snapshot failed"]
        case "scrollers":
            return await page.debugScrollers()
        case "command":
            let command = params["command"]?.stringValue ?? "find"
            var arguments: [String: JSONValue] = [:]
            if let text = params["text"] { arguments["text"] = text }
            return ["handled": .bool(page.send(command: command, arguments: arguments))]
        case "click":
            guard let selector = params["selector"]?.stringValue else { return ["error": "selector is required"] }
            return ["clicked": .bool(await page.debugClick(selector, metaKey: params["meta"]?.boolValue == true,
                                                           contextMenu: params["context_menu"]?.boolValue == true))]
        case "hover":
            guard let selector = params["selector"]?.stringValue else { return ["error": "selector is required"] }
            return await page.debugHover(selector)
        case "scroll":
            guard let selector = params["selector"]?.stringValue else { return ["error": "selector is required"] }
            let block = params["block"]?.stringValue ?? "start"
            guard ["start", "center", "end", "nearest"].contains(block) else {
                return ["error": "block must be one of start, center, end, nearest"]
            }
            let scrolled = await page.debugScroll(selector, block: block)
            guard scrolled["scrolled"] != true else { return scrolled }
            // "no element matches" while the page has not drawn it yet (a card the host fills in later):
            // a caller may wait; "not in view" is final.
            let reason = scrolled["reason"]?.stringValue ?? "no match"
            if reason == "not in view" { return ["error": .string("\(selector) is not in view after the scroll")] }
            return ["error": .string("no element matches \(selector) (\(reason))")]
        case "query":
            return await page.debugQuery(params["selector"]?.stringValue ?? "*")
        case "route":
            page.open(route: params["route"]?.stringValue ?? "/"); return ["ok": true] // a hash route, as a hand-off opens it
        case "type":
            guard let text = params["text"]?.stringValue else { return ["error": "text is required"] }
            return ["inserted": .bool(await page.debugInsertText(text, selector: params["selector"]?.stringValue))]
        case "call":
            guard let op = params["op"]?.stringValue else { return ["error": "op is required"] }
            return await page.router.handle(["t": "call", "id": 1, "op": .string(op), "params": params["params"] ?? .object([:])])
        case "hangOnClick":
            let armed = await page.callPageFunction("addEventListener('mousedown', () => { for (;;) {} }); return true;")
            return ["armed": .bool(armed as? Bool == true)]
        case "connected":
            page.setConnected(params["value"]?.boolValue ?? true)
            return ["connected": .bool(page.router.connected)]
        case "ping":
            return await ping(page)
        default:
            return ["error": "unknown action"]
        }
    }

    /// `ping` (p13-webui-079's delivery bench, `bench-webui.py push`): one host call the page serves no handler
    /// for, so it answers `unknown_op`. `ms` is the call's round trip, from its send to the page's answer: one
    /// delivery into the page (data on the page push channel, else a script) and the page's reply.
    @MainActor
    private static func ping(_ page: PageWebView) async -> JSONValue {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await page.router.callPage(benchPingOp, params: [:])
        } catch let error as PageError where error.code == PageError.unknownOp(benchPingOp).code {
            // The answer the ping asks for.
        } catch {
            return ["error": .string("\(error)")]
        }
        return ["ms": .number((ProcessInfo.processInfo.systemUptime - started) * 1000)]
    }

    /// The op `ping` calls; no page serves it.
    private static let benchPingOp = "cmux.bench.ping"

    /// Which live view a probe read.
    @MainActor
    private static func identity(_ page: PageWebView) -> [String: JSONValue] {
        var members: [String: JSONValue] = [
            "page": .string(page.pageID),
            "instance": .number(Double(PageRegistry.instance(of: page))),
            "parked": .bool(page.isParkedSpare),
            "window_number": page.window.map { .number(Double($0.windowNumber)) } ?? .null,
        ]
        if let claim = page.lastClaim {
            members["claim"] = ["path": .string(claim.path.rawValue), "ms": .number(claim.milliseconds)]
        }
        return members
    }
}

/// The oracle's `webviews` facet: each page a person can reach (in a tab or a window, never a
/// parked spare) answers `cmux.page.oracle.state`, placed by the page or agent tab whose view holds it.
extension AppServices {
    /// How long the facet waits for the pages' answers (they are asked together, so one deadline in all).
    static let oracleWebviewsDeadline: Duration = .seconds(1)

    func oracleWebviews(within deadline: Duration = AppServices.oracleWebviewsDeadline,
                        clock: any Clock<Duration> = ContinuousClock()) async throws(OracleFacetError) -> OracleWebviewsFacet.Reading {
        let asked = WebUIHost.oracleReachable(webUI.registry.pages(), places: oraclePagePlaces(), spare: newTabSpares.spare?.view)
            .map { $0.page }
        let answers = await webUI.oracleStates(of: asked, within: deadline, clock: clock)
        // Placed after every answer, in one turn with a fresh place map: no await falls between the map and its
        // lookups, and `asked` holds every page, so no view's identifier is reused meanwhile. A page that left every
        // tab and window while it answered is gone.
        var reading = OracleWebviewsFacet.Reading()
        for (page, place) in WebUIHost.oracleReachable(asked, places: oraclePagePlaces(), spare: newTabSpares.spare?.view) {
            let answer: PageWebView.OracleStateAnswer?
            switch answers[ObjectIdentifier(page)] {
            case .success(let value)?: answer = value
            case .failure(let error)?: throw OracleFacetError("page \(page.pageID): \(error.code) \(error.message)")
            case nil: answer = nil
            }
            switch answer {
            case .state(let state)?:
                reading.pages.append(try OracleWebviewsFacet.Page(page: page.pageID, tab: place?.tab, pane: place?.pane,
                                                                  answer: state.foundationObject))
            case .unserved?: reading.unserved.append(page.pageID)
            case .loading?: reading.loading.append(page.pageID)
            case .timedOut?: reading.timedOut.append(page.pageID)
            case .gone?, nil: continue
            }
        }
        return reading
    }

    /// The view of each page tab and made agent tab, by its tab and pane (no lookup makes a view or starts acpmux).
    private func oraclePagePlaces() -> [ObjectIdentifier: OraclePagePlace] {
        var places: [ObjectIdentifier: OraclePagePlace] = [:]
        for (workspace, _) in machines.allWorkspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                for tab in pane.tabs.map(\.id) + pages.tabIDs(in: pane.id) {
                    var view: NSView? = pages.existingView(tab)
                    if view == nil { view = madeAgentTabs?.existingView(tab) }
                    if let view { places[ObjectIdentifier(view)] = OraclePagePlace(tab: tab, pane: pane.id) }
                }
            }
        }
        return places
    }
}
#endif
