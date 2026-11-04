public import CmuxNextSettings
import Foundation

/// The native agent-pane debug request's positional arguments, passed unchanged to its web handler.
public struct AgentPaneDebugAutomationArguments {
    private let action: String
    private let params: [String: JSONValue]

    /// The named page action and the native control request's named parameters.
    public init(action: String, parameters: [String: JSONValue]) {
        self.action = action
        params = parameters
    }

    /// Foundation values in the order the page handler accepts.
    public var values: [Any] {
        switch action {
        case "seed_rows":
            // `agents`: how many subagents the `subagents` fixture starts (2 when omitted).
            return [params["count"]?.intValue ?? 5000, params["fixture"]?.stringValue.map { $0 as Any } ?? NSNull(),
                    params["agents"]?.intValue.map { $0 as Any } ?? NSNull()]
        case "fling":
            var options: [String: Any] = ["wait": params["wait"]?.boolValue == true]
            if let nominal = params["nominal_ms"]?.doubleValue { options["nominal_ms"] = nominal }
            return [params["seconds"]?.doubleValue ?? 3, options]
        case "perf_stats":
            return [["raw": params["raw"]?.boolValue == true] as [String: Any]]
        case "stream":
            // R104: a scripted reply streamed into `rows` synthetic rows (streamDebug.ts).
            var options: [String: Any] = [:]
            for key in ["rows", "seconds", "chunk_chars", "chunk_ms", "nominal_ms", "trace"] {
                if let value = params[key]?.doubleValue { options[key] = value }
            }
            return [options]
        case "load_seed":
            return [params["turns"]?.intValue ?? 5000]
        case "load_run", "layout_watch":
            // The chat under load (loadDebug.ts), or what moved after the page's first paint (layoutWatch.ts).
            var options: [String: Any] = [:]
            for key in ["seconds", "chunk_chars", "chunk_ms", "tool_every", "scroll_speed", "scroll_depth", "ms", "tolerance"] {
                if let value = params[key]?.doubleValue { options[key] = value }
            }
            return [options]
        case "idle_probe":
            // What the page asks for while nobody touches it (idleProbe.ts), over `ms`.
            return [params["ms"]?.doubleValue.map { ["ms": $0] as [String: Any] } ?? [:]]
        case "open_menu":
            return [params["label"]?.stringValue ?? ""]
        case "acp_log":
            return [params["limit"]?.intValue.map { ["limit": $0] as [String: Any] } ?? [:]]
        case "send_prompt", "compose_send":
            return [params["text"]?.stringValue ?? ""]
        case "run_mode":
            return [params["mode"]?.stringValue ?? NSNull()]
        case "new_chat":
            return [params["harness"]?.stringValue ?? NSNull(), params["cwd"]?.stringValue ?? NSNull()]
        case "set_model":
            return [params["model"]?.stringValue ?? "", params["effort"]?.stringValue ?? NSNull()]
        case "select_session":
            return [params["session"]?.stringValue ?? ""]
        case "pick_folder":
            return [params["cwd"]?.stringValue ?? ""]
        case "answer_permission":
            var options: [String: Any] = [:]
            if let option = params["option"]?.stringValue { options["optionId"] = option }
            if let allow = params["allow"]?.boolValue { options["allow"] = allow }
            if let decision = params["decision"]?.stringValue { options["decision"] = decision }
            return [options]
        default:
            return []
        }
    }
}
