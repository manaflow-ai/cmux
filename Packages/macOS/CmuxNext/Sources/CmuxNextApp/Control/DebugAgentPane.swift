#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextSettings
import WebKit

/// `debug.agent_pane` (DEBUG builds): performance measurement of the React
/// agent pane through the page's `window.cmuxAcpmuxDebug`, the counterpart
/// of the native pane's seed and fling measurements. Targets the agent tab
/// shown in `pane` (default: the focused pane of the first window showing
/// one). Never changes focus.
///
/// `action`: `seed_rows` (`count`, default 5000), `fling` (`seconds`,
/// default 3; `nominal_ms`; `wait` returns the stats when the fling ends),
/// `fling_stats`, `perf_stats` (`raw` adds every frame), `typing_stats`,
/// `reset_typing`, or `pid` (the WebContent process, for profiling).
@MainActor
enum DebugAgentPane {
    /// Long enough for a 5000-row seed and a waited fling of up to ~25 s.
    static let deadline: Duration = .seconds(30)

    private static let functions: [String: String] = [
        "seed_rows": "seedRows", "fling": "startFling", "fling_stats": "flingStats",
        "perf_stats": "perfStats", "typing_stats": "typingStats", "reset_typing": "resetTyping",
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
        if action == "pid" {
            let selector = NSSelectorFromString("_webProcessIdentifier")
            guard view.webView.responds(to: selector),
                  let pid = (view.webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else {
                return .object(["pane": .string(pane), "error": .string("no WebContent process")])
            }
            return .object(["pane": .string(pane), "pid": .number(Double(pid))])
        }
        guard let function = functions[action] else {
            return .object(["error": .string("unknown action; use seed_rows, fling, fling_stats, perf_stats, typing_stats, reset_typing or pid")])
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
