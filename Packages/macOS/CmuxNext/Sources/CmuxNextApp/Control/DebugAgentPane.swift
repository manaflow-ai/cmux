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
/// `action`: `seed_rows` (`count`, default 5000; `fixture: "worked-turn"`
/// seeds a turn that edits three files instead, for the changes view), `fling` (`seconds`,
/// default 3; `nominal_ms`; `wait` returns the stats when the fling ends),
/// `fling_stats`, `perf_stats` (`raw` adds every frame), `typing_stats`,
/// `reset_typing`, `open_menu` (`label`: opens that composer menu, such as
/// `Model` or `Mode`, through the same path as a click, for automation and
/// captures), `acp_log` (the page's acpmux wire log and its stats; `limit`
/// keeps the newest entries), `acp_log_export` (that log as JSON Lines),
/// the chat automation verbs (webviews automation.ts; each runs the page
/// action a click or key runs, so a no-activate window can be driven end to
/// end): `chat_state`, `send_prompt` (`text`), `new_chat` (`harness`, `cwd`),
/// `select_session` (`session`), `answer_permission` (`option`, `allow`,
/// `decision`), `open_changes` (the latest turn's changes view),
/// `models` (the harness's models), `set_model` (`model`, `effort`),
/// `readiness` (page body, transcript and composer metrics), `pid` (the WebContent process, for profiling), or
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
        "chat_state": "chatState", "send_prompt": "sendPrompt", "new_chat": "newChat",
        "select_session": "selectSession", "answer_permission": "answerPermission", "open_changes": "openChanges",
        "set_model": "setModel", "models": "models", "stream": "stream",
    ]

    /// Runs `fn(...args)` on the page and returns its result as JSON text.
    private static let script = """
        let debug = window.cmuxAcpmuxDebug;
        for (let frame = 0; !debug && frame < 120; frame += 1) {
            await new Promise(requestAnimationFrame);
            debug = window.cmuxAcpmuxDebug;
        }
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
        if action == "gesture_state" {
            // The relay's gesture record (no ticket value), for a live repro of a gesture refusal.
            let state = view.model.transport.gestures.debugState
            var fields: [String: JSONValue] = ["pane": .string(pane), "available": .bool(state.available), "tickets": .number(Double(state.tickets))]
            fields["age_seconds"] = state.ageSeconds.map { .number($0) } ?? .null
            return .object(fields)
        }
        if action == "full_rate" {
            if let enabled = params["enabled"]?.boolValue { view.rendersAtFullRate = enabled }
            return .object(["pane": .string(pane), "full_rate": .bool(view.rendersAtFullRate)])
        }
        if action == "readiness" {
            return await readiness(pane: pane, view: view)
        }
        guard let function = functions[action] else {
            return .object(["error": .string("unknown action; use seed_rows, fling, fling_stats, perf_stats, typing_stats, reset_typing, open_menu, acp_log, acp_log_export, chat_state, send_prompt, new_chat, select_session, answer_permission, open_changes, set_model, models, stream, readiness, pid, full_rate or gesture_state")])
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

    private static func readiness(pane: String, view: AgentPaneView) async -> JSONValue {
        let script = """
        const bodyText = (document.body?.innerText || '').trim();
        const composer = document.querySelector('.acpmux-composer');
        const composerRect = composer?.getBoundingClientRect();
        const debug = window.cmuxAcpmuxDebug;
        const state = debug && typeof debug.chatState === 'function' ? debug.chatState() : {};
        const transcriptRows = Number(state.rows || 0) || document.querySelectorAll('.cv-worked, .cv-message, .cv-tool, .cv-turn-actions').length;
        return JSON.stringify({
          body_text_length: bodyText.length,
          transcript_rows: transcriptRows,
          composer_visible: !!composer && !!composerRect && composerRect.width > 0 && composerRect.height > 0,
          composer_text_length: (composer?.innerText || '').trim().length,
          document_ready: document.readyState === 'complete'
        });
        """
        do {
            let result = try await view.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            guard let text = result as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
                  let value = JSONValue(foundation: object),
                  case .object(var members) = value else {
                return .object(["pane": .string(pane), "error": .string("the page returned no readiness JSON")])
            }
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
            return [params["count"]?.intValue ?? 5000, params["fixture"]?.stringValue.map { $0 as Any } ?? NSNull()]
        case "fling":
            var options: [String: Any] = ["wait": params["wait"]?.boolValue == true]
            if let nominal = params["nominal_ms"]?.doubleValue { options["nominal_ms"] = nominal }
            return [params["seconds"]?.doubleValue ?? 3, options]
        case "perf_stats":
            return [["raw": params["raw"]?.boolValue == true] as [String: Any]]
        case "stream":
            // R104: a scripted reply streamed into `rows` synthetic rows (streamDebug.ts).
            var options: [String: Any] = [:]
            for key in ["rows", "seconds", "chunk_chars", "chunk_ms", "nominal_ms"] {
                if let value = params[key]?.doubleValue { options[key] = value }
            }
            return [options]
        case "open_menu":
            return [params["label"]?.stringValue ?? ""]
        case "acp_log":
            return [params["limit"]?.intValue.map { ["limit": $0] as [String: Any] } ?? [:]]
        case "send_prompt":
            return [params["text"]?.stringValue ?? ""]
        case "new_chat":
            return [params["harness"]?.stringValue ?? NSNull(), params["cwd"]?.stringValue ?? NSNull()]
        case "set_model":
            return [params["model"]?.stringValue ?? "", params["effort"]?.stringValue ?? NSNull()]
        case "select_session":
            return [params["session"]?.stringValue ?? ""]
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
