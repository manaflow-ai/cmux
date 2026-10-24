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
//   `full`, `near60`, or `unknown` when this WebKit has no such feature; `chromium` names the
//   engine only, its rate is not read), `display_fps`, `low_power_mode` (macOS's own: WebKit
//   halves a page's rate in it by itself; `debug.low_power_mode` does not reach it), `painted` (the document's first frame, with
//   `painted_uptime` in host systemUptime seconds and `painted_ms` on the page clock), `instance`,
//   `parked`, `window_number` and `claim` (how a pooled host took its last claim: `path`
//   acknowledged / refused / timedOut / loaded, `ms`) and `in_flight` (the page's calls still
//   running: id, op, age_ms);
// - `frames` (`window_ms` default 1000, at most 1500; `scroll_px`, default 0; `selector`?): the
//   page's own requestAnimationFrame intervals over the window (`PageFrameCadence`: frames,
//   observed_fps, p50/p95/max_ms, long_frames over 1.5 refreshes (null without display_fps),
//   intervals_ms, scrolled_px), with `engine`, `render_rate`, `display_fps` and `low_power_mode`,
//   so one reply says whether a cadence number is valid (scripts/cmux-next/bench-page-cadence.py:
//   engine webkit on a display above 60 Hz). `scroll_px` > 0 scrolls the element matching
//   `selector` (default the document's scroller) that far each frame, and `scrolled_px` says how
//   far it really moved (0: that element does not scroll, as Settings' document does not; its
//   scroller is `.content`). An invalid selector, or one that matches nothing, is an error;
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
                members.merge(rate(page)) { _, new in new }
                state = .object(members)
            }
            return state
        case "frames":
            let cadence: PageFrameCadence
            do throws(PageFrameCadence.ProbeError) {
                cadence = try await page.debugFrameCadence(windowMs: params["window_ms"]?.doubleValue ?? 1000,
                                                           scrollPixels: params["scroll_px"]?.doubleValue ?? 0,
                                                           selector: params["selector"]?.stringValue,
                                                           displayFPS: displayFPS(page))
            } catch {
                return ["error": .string(error.message)]
            }
            guard case .object(var members) = cadence.json else { return ["error": "page not loaded"] }
            members["engine"] = .string(page.showsChromium ? "chromium" : "webkit")
            members.merge(rate(page)) { _, new in new }
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

    /// How fast the page renders, read live: `render_rate` (`full` or `near60` from WebKit's
    /// PreferPageRenderingUpdatesNear60FPSEnabled, `unknown` for a WebKit without that feature,
    /// `chromium` for a Chromium page: this names the engine and reads no rate), `display_fps`
    /// (the highest rate of the page's display, null without a window) and `low_power_mode`
    /// (macOS's, which WebKit's own throttling follows: half the rate while it is on).
    @MainActor
    private static func rate(_ page: PageWebView) -> [String: JSONValue] {
        let renderRate: String
        if page.showsChromium {
            renderRate = "chromium"
        } else if let near60 = page.webKitView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature) {
            renderRate = near60 ? "near60" : "full"
        } else {
            renderRate = "unknown"
        }
        return ["render_rate": .string(renderRate), "display_fps": displayFPS(page).map { .number($0) } ?? .null,
                "low_power_mode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)]
    }

    /// The highest rate of the display the page is on; nil without a window.
    @MainActor
    private static func displayFPS(_ page: PageWebView) -> Double? {
        page.window?.screen.map { Double($0.maximumFramesPerSecond) }
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
