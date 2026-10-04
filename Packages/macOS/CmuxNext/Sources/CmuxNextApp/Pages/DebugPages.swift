import CmuxNextControl
import CmuxNextPages
import CmuxNextSettings
import Foundation

// `debug.page` (DEBUG builds): the generic page verb for every React page
// (plans/cmux-next/react-pages.md), from the Settings lead's `debug.settings_web`.
// Params: `page` (id, default the first live page), `action`:
// - `state` (default): page id, URL fragment, language, visible text, control count, computed
//   html/body backgrounds (the one-backdrop check);
// - `snapshot` (`path`, default /tmp/cmux-page-<id>.png): the page as WebKit rendered it;
// - `command` (`command`, `text`): a dispatcher command (`find`, `focusSearch`, `back`, `forward`,
//   `reset`) on the page's command stream, as the key dispatcher sends it;
// - `connected` (`value` bool): the owner link state on the page's connection stream;
// - `call` (`op`, `params`): one call message through the page's router, exactly as the page's
//   bridge sends it (the host sets the calling page's id). With `page: "cmux.cloud"` and no live
//   Cloud page, a hidden one is made first (the app has no Cloud page entry yet).
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
        guard let page = PageRegistry.pages(id: id).first else {
            return ["error": .string("no live page\(id.map { " " + $0 } ?? "")")]
        }
        switch params["action"]?.stringValue ?? "state" {
        case "state":
            var state = await page.debugState()
            if case .object(var members) = state {
                members["page"] = .string(page.pageID)
                members["subscriptions"] = .number(Double(page.router.subscriptionCount))
                state = .object(members)
            }
            return state
        case "snapshot":
            let path = params["path"]?.stringValue ?? "/tmp/cmux-page-\(page.pageID).png"
            let written = await page.debugSnapshot(to: URL(fileURLWithPath: path))
            return written ? ["path": .string(path)] : ["error": "snapshot failed"]
        case "command":
            let command = params["command"]?.stringValue ?? "find"
            var arguments: [String: JSONValue] = [:]
            if let text = params["text"] { arguments["text"] = text }
            return ["handled": .bool(page.send(command: command, arguments: arguments))]
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
}
#endif
