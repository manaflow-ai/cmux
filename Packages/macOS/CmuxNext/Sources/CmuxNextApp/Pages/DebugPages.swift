import AppKit
import CmuxNextControl
import CmuxNextPages
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
//   acknowledged / refused / timedOut / loaded, `ms`) and `in_flight` (the page's calls still
//   running: id, op, age_ms);
// - `snapshot` (`path`, default /tmp/cmux-page-<id>.png): the page as WebKit rendered it;
// - `command` (`command`, `text`): a dispatcher command (`find`, `focusSearch`, `back`, `forward`,
//   `reset`) on the page's command stream, as the key dispatcher sends it;
// - `connected` (`value` bool): the owner link state on the page's connection stream;
// - `scrollers`: `data-scrollers` and every element that shows a scroller at rest under "Always"
//   (overflowing auto/scroll boxes with their overflow in pixels; SCROLLBARS-THIN audit);
// - `click` (`selector`, `context_menu`?): clicks (or right-clicks) the first element matching the CSS selector
//   (`click`, `drag`, `press`: an error when the input did not happen, so a capture step fails);
// - `scroll` (`selector`, `block`? start | center | end | nearest, default start): scrolls the first
//   matching element into view at once (every scroller that holds it): `{scrolled, top, height,
//   viewport}` once its box is in view; an error when nothing rendered matches or it is still out of view,
//   so a capture step fails instead of shooting the fold;
// - `hover` (`selector`): moves the mouse onto the first matching element (a capture slot's window
//   never activates, so no pointer reaches its pages): `{hovered, native, x, y}`;
// - `query` (`selector`): each matching element's data-* attributes, classes, text, and its `role` and
//   accessible `label` when it has them, in document order (PageDebugQuery);
// - `wait` (`selector`, `timeout_ms`, max 90000): one rendered selector match, observed without polling;
// - `type` (`text`, `selector`?): inserts text as typed input in the matching (else the focused) element;
// - `call` (`op`, `params`): one call message through the page's router, exactly as the page's
//   bridge sends it (the host sets the calling page's id). With `page: "cmux.cloud"` and no live
//   Cloud page, a hidden one is made first (so a probe needs no open Cloud tab);
// - `open` (`route`?): a hidden live page of `page` when none is live, so the other actions have one to
//   read: `cmux.cloud`, or `cmux.feed` on `route` (default `#/needs-you`, the one route the app opens;
//   the app shows the Feed only in Chief Home's Needs you, opt-in and only while something waits, so a
//   fresh run has none). Answers the page's identity with `made` (false: a live one was already there).
// The control router's deadline bounds every action.
extension AppControl {
    func registerPageDebugMethods(_ services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        service?.router.register([
            .async("debug.page") { [weak services] call in await DebugPages.handle(call.params, services: services) }
                .withLimit { request, _ in request.params["action"]?.stringValue == "wait" ? .seconds(95) : nil },
        ])
        #endif
    }
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
        if params["action"]?.stringValue == "open" {
            return open(id, route: params["route"]?.stringValue, services: services)
        }
        if params["action"]?.stringValue == "list" {
            return ["pages": .array(PageRegistry.pages(id: id, probing: true).map { .object($0.debugIdentity) })]
        }
        let instance = params["instance"]?.intValue.map { UInt64(max($0, 0)) }
        guard let page = PageRegistry.probeTarget(id: id, parked: params["parked"]?.boolValue == true,
                                                  instance: instance) else {
            return ["error": .string("no live page\(id.map { " " + $0 } ?? "")")]
        }
        switch params["action"]?.stringValue ?? "state" {
        case "state":
            return await page.debugFullState()
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
            return await page.debugClick(selector, metaKey: params["meta"]?.boolValue == true, contextMenu: params["context_menu"]?.boolValue == true) ? ["clicked": .bool(true)] : ["error": .string("no element matches \(selector)")]
        case "drag":
            let numbers = ["x1", "y1", "x2", "y2"].compactMap { params[$0]?.doubleValue }
            guard numbers.count == 4 else { return ["error": "x1, y1, x2, y2 (CSS pixels) are required"] }
            return await page.debugDrag(from: CGPoint(x: numbers[0], y: numbers[1]), to: CGPoint(x: numbers[2], y: numbers[3]), steps: params["steps"]?.intValue ?? 16)
                ? ["dragged": .bool(true)] : ["error": "the drag did not reach the page: it shows in WebKit, or DevTools refused an event"]
        case "press":
            let numbers = ["x", "y"].compactMap { params[$0]?.doubleValue }
            guard numbers.count == 2 else { return ["error": "x, y (CSS pixels) are required"] }
            return await page.debugPress(x: numbers[0], y: numbers[1], native: params["native"]?.boolValue == true) ? ["pressed": .bool(true)] : ["error": "the press did not reach the page"]
        case "paste": return await page.debugPaste()
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
        case "wait":
            guard let selector = params["selector"]?.stringValue else { return ["error": "selector is required"] }
            return await page.debugWait(selector: selector, timeoutMilliseconds: params["timeout_ms"]?.intValue ?? 30_000)
        case "route":
            page.open(route: params["route"]?.stringValue ?? "/"); return ["ok": true] // a hash route, as a hand-off opens it
        case "type":
            guard let text = params["text"]?.stringValue else { return ["error": "text is required"] }
            return ["inserted": .bool(await page.debugInsertText(text, selector: params["selector"]?.stringValue))]
        case "call":
            guard let op = params["op"]?.stringValue else { return ["error": "op is required"] }
            return await page.router.handle(["t": "call", "id": 1, "op": .string(op), "params": params["params"] ?? .object([:])])
        case "connected":
            page.setConnected(params["value"]?.boolValue ?? true)
            return ["connected": .bool(page.router.connected)]
        default:
            return ["error": "unknown action"]
        }
    }

    /// The page ids `open` can make hidden.
    @MainActor static let openable = [PageDescriptor.cloud.id, PageDescriptor.feed.id]

    /// `open`: the live page of `id`, else a hidden one made through the app's own factory.
    @MainActor
    static func open(_ id: String?, route: String?, services: AppServices?) -> JSONValue {
        guard let id, openable.contains(id) else {
            return ["error": .string("open makes only \(openable.joined(separator: ", ")) pages")]
        }
        if let live = PageRegistry.probeTarget(id: id) {
            return .object(live.debugIdentity.merging(["made": false]) { _, new in new })
        }
        guard let services else { return ["error": "no app services"] }
        let factory = PageFactory(services: services)
        let made = id == PageDescriptor.feed.id ? factory.feedWebPage(route: route ?? "#/needs-you") : factory.cloudWebPage()
        guard let made else { return ["error": .string("no \(id) page: its resources are missing")] }
        Self.made.append(made)
        return .object(made.debugIdentity.merging(["made": true]) { _, new in new })
    }
}
#endif
