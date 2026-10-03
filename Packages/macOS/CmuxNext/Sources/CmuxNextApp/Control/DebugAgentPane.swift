#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextSettings
import ObjectiveC
import WebKit

/// `debug.agent_pane` (DEBUG builds): performance measurement of the React
/// agent pane through the page's `window.cmuxAcpmuxDebug`, the counterpart
/// of the native pane's seed and fling measurements. Targets the agent tab
/// shown in `pane` (default: the focused pane of the first window showing
/// one). Never changes app or window focus; `open_menu` moves focus inside
/// the page to the menu's button, as a click does.
///
/// `action`: `seed_rows` (`count`, default 5000), `fling` (`seconds`,
/// default 3; `nominal_ms`; `wait` returns the stats when the fling ends),
/// `fling_stats`, `perf_stats` (`raw` adds every frame), `typing_stats`,
/// `reset_typing`, `open_menu` (`label`: opens that composer menu, such as
/// `Model` or `Mode`, through the same path as a click, for automation and
/// captures), `acp_log` (the page's acpmux wire log and its stats; `limit`
/// keeps the newest entries), `acp_log_export` (that log as JSON Lines),
/// `pid` (the WebContent process, for profiling), or
/// `full_rate` (`enabled` turns full-rate rendering on or off on the live
/// page; returns whether it is on). Every action first stops WebKit from
/// pausing the page while another window covers it, so a tagged build can
/// be measured behind the user's windows.
@MainActor
enum DebugAgentPane {
    /// Long enough for a 5000-row seed and a waited fling of up to ~25 s.
    static let deadline: Duration = .seconds(30)

    private static let functions: [String: String] = [
        "seed_rows": "seedRows", "fling": "startFling", "fling_stats": "flingStats",
        "perf_stats": "perfStats", "typing_stats": "typingStats", "reset_typing": "resetTyping",
        "open_menu": "openMenu", "acp_log": "acpLog", "acp_log_export": "acpLogExport",
    ]

    /// Runs `fn(...args)` on the page and returns its result as JSON text.
    private static let script = """
        const debug = window.cmuxAcpmuxDebug;
        if (!debug || typeof debug[fn] !== "function") return JSON.stringify({ error: "the page has no cmuxAcpmuxDebug." + fn });
        return JSON.stringify((await debug[fn](...args)) ?? null);
        """

    static func handle(_ params: [String: JSONValue], _ services: AppServices?) async -> JSONValue {
        guard let services, let (pane, view) = agentPane(params, services: services) else {
            return .object(["error": .string("no agent tab in the given or focused pane")])
        }
        let action = params["action"]?.stringValue ?? ""
        keepRenderingWhenCovered(view.webView)
        if action == "pid" {
            let selector = NSSelectorFromString("_webProcessIdentifier")
            guard view.webView.responds(to: selector),
                  let pid = (view.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else {
                return .object(["pane": .string(pane), "error": .string("no WebContent process")])
            }
            return .object(["pane": .string(pane), "pid": .number(Double(pid))])
        }
        if action == "full_rate" {
            if let enabled = params["enabled"]?.boolValue { view.rendersAtFullRate = enabled }
            return .object(["pane": .string(pane), "full_rate": .bool(view.rendersAtFullRate)])
        }
        guard let function = functions[action] else {
            return .object(["error": .string("unknown action; use seed_rows, fling, fling_stats, perf_stats, typing_stats, reset_typing, open_menu, acp_log, acp_log_export, pid or full_rate")])
        }
        do {
            let result = try await view.webView.callAsyncJavaScript(
                script, arguments: ["fn": function, "args": arguments(action, params)], in: nil, contentWorld: .page
            )
            guard let text = result as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
                  let value = JSONValue(foundation: object) else {
                return .object(["pane": .string(pane), "error": .string("the page returned no JSON")])
            }
            guard case .object(var members) = value else { return .object(["pane": .string(pane), "result": value]) }
            members["pane"] = .string(pane)
            return .object(members)
        } catch {
            return .object(["pane": .string(pane), "error": .string(String(describing: error))])
        }
    }

    /// `-[WKWebView _setWindowOcclusionDetectionEnabled:]`, when this WebKit has it.
    private static func keepRenderingWhenCovered(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(webView, selector, false)
    }

    /// The page function's positional arguments, as Foundation values.
    private static func arguments(_ action: String, _ params: [String: JSONValue]) -> [Any] {
        switch action {
        case "seed_rows":
            return [params["count"]?.intValue ?? 5000]
        case "fling":
            var options: [String: Any] = ["wait": params["wait"]?.boolValue == true]
            if let nominal = params["nominal_ms"]?.doubleValue { options["nominal_ms"] = nominal }
            return [params["seconds"]?.doubleValue ?? 3, options]
        case "perf_stats":
            return [["raw": params["raw"]?.boolValue == true] as [String: Any]]
        case "open_menu":
            return [params["label"]?.stringValue ?? ""]
        case "acp_log":
            return [params["limit"]?.intValue.map { ["limit": $0] as [String: Any] } ?? [:]]
        default:
            return []
        }
    }

    /// The agent page shown in `pane`, or in the first window whose focused
    /// pane shows one.
    private static func agentPane(_ params: [String: JSONValue], services: AppServices) -> (String, AgentPaneView)? {
        let requested = params["pane"]?.stringValue
        for controller in services.windows.controllers {
            guard let content = controller.content else { continue }
            let candidate: PaneController?
            if let requested {
                candidate = content.paneController(key: requested)
            } else {
                candidate = content.focusedPane
            }
            guard let paneController = candidate,
                  let key = paneController.currentTabKey,
                  let view = services.agentTabs.existingView(key) else { continue }
            return (paneController.paneKey, view)
        }
        return nil
    }
}
#endif
