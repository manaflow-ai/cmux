import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import WebKit

// `debug.page` (DEBUG builds): the generic page verb for every React page
// (plans/cmux-next/react-pages.md), from the Settings lead's `debug.settings_web`.
// Params: `page` (id; nil: any page), `instance` (a number from `list` or `state`), `parked`
// (true: the pool's parked spare). Without `instance` the target is a page that is not the parked
// spare (its document has no routes, so probes of it saw a failed-read banner no visible page
// showed), the one in the key window first, else the newest. `action`:
// - `list`: every live page of the id: instance, parked, window number, claim outcome;
// - `state` (default): page id, URL fragment, language, visible text, control count, computed
//   html/body backgrounds (the one-backdrop check), `render_rate` (WebKit's live preference:
//   `full`, `near60`, or `unknown` when this WebKit has no such feature, the case where pages stay
//   near 60; `chromium` names the engine only, its rate is not read) and `display_fps`, `events_held`
//   and `events_waiting` (a page nobody can see gets no events until it shows), `painted` (the document's first frame, with
//   `painted_uptime` in host systemUptime seconds and `painted_ms` on the page clock), `instance`,
//   `parked`, `window_number` and `claim` (how a pooled host took its last claim: `path`
//   acknowledged / refused / timedOut / loaded, `ms`) and `in_flight` (the page's calls still
//   running: id, op, age_ms);
// - `frames` (`window_ms` default 1000, at most 1500; `scroll_px`, default 0; `selector`?): the
//   page's own requestAnimationFrame intervals over the window (`PageFrameCadence`: frames,
//   observed_fps, p50/p95/max_ms, long_frames over 1.5 refreshes, intervals_ms), with `engine`,
//   `render_rate` and `display_fps`, so one reply says whether a cadence number is valid (row 23
//   needs engine webkit on a 120 Hz display; a default build opens Settings, History and Cloud in
//   Chromium). `scroll_px` > 0 scrolls the page's scroller that far each frame;
// - `snapshot` (`path`, default /tmp/cmux-page-<id>.png): the page as WebKit rendered it;
// - `command` (`command`, `text`): a dispatcher command (`find`, `focusSearch`, `back`, `forward`,
//   `reset`) on the page's command stream, as the key dispatcher sends it;
// - `connected` (`value` bool): the owner link state on the page's connection stream;
// - `scrollers`: `data-scrollers` and every element that shows a scroller at rest under "Always"
//   (overflowing auto/scroll boxes with their overflow in pixels; SCROLLBARS-THIN audit);
// - `click` (`selector`, `context_menu`?): clicks (or right-clicks) the first element matching the CSS selector;
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
        #if DEBUG
        service?.router.register([
            .async("debug.page") { [weak services] call in await DebugPages.handle(call.params, services: services) },
        ])
        #endif
    }
}

#if DEBUG
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
                // A page nobody can see gets no events until it shows (PageRouter.isPageHidden).
                members["events_held"] = .bool(page.router.isPageHidden)
                members["events_waiting"] = .number(Double(page.router.heldCount))
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
                // How fast it renders, against the display it is on (perf: every page at full rate).
                members["render_rate"] = .string(renderRate(page))
                members["display_fps"] = page.window?.screen.map { .number(Double($0.maximumFramesPerSecond)) } ?? .null
                state = .object(members)
            }
            return state
        case "frames":
            let displayFPS = page.window?.screen.map { Double($0.maximumFramesPerSecond) }
            guard let cadence = await page.debugFrameCadence(windowMs: params["window_ms"]?.doubleValue ?? 1000,
                                                             scrollPixels: params["scroll_px"]?.doubleValue ?? 0,
                                                             selector: params["selector"]?.stringValue,
                                                             displayFPS: displayFPS),
                  case .object(var members) = cadence.json else { return ["error": "page not loaded"] }
            members["engine"] = .string(page.showsChromium ? "chromium" : "webkit")
            members["render_rate"] = .string(renderRate(page))
            members.merge(identity(page)) { _, new in new }
            return .object(members)
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

    /// How fast the page renders: `full` or `near60` (WebKit's live
    /// PreferPageRenderingUpdatesNear60FPSEnabled), `unknown` (a WebKit without that feature), or
    /// `chromium` (a Chromium page; this names the engine and reads no rate).
    @MainActor
    private static func renderRate(_ page: PageWebView) -> String {
        if page.showsChromium { return "chromium" }
        guard let near60 = page.webKitView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature)
        else { return "unknown" }
        return near60 ? "near60" : "full"
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
