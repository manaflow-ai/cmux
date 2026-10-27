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
// The control router's deadline bounds every action.
extension AppControl {
    func registerPageDebugMethods(_ services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        service?.router.register([
            .async("debug.page") { [weak services] call in await DebugPages.handle(call.params, services: services) },
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
                // Why a page may not paint: no window, a hidden view, or a window macOS reports
                // as occluded (WebKit stops rendering updates for an occluded window).
                members["in_window"] = .bool(page.window != nil)
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
            if reason == "not in view" || reason == "top covered" {
                return ["error": .string("\(selector) is \(reason) after the scroll")]
            }
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
        case "connected":
            page.setConnected(params["value"]?.boolValue ?? true)
            return ["connected": .bool(page.router.connected)]
        default:
            return ["error": "unknown action"]
        }
    }

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
#endif
