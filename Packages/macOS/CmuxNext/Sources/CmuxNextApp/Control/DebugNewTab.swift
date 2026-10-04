#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextSettings
import Darwin
import WebKit

/// `debug.new_tab` (DEBUG builds): the instant new tab measurements
/// (plans/cmux-next/new-tab.md section 2.3). Never changes app focus.
///
/// `action`: `state` (each window's spare: its WebContent pid and physical
/// footprint, and the recorded openings: spare or cold, main-thread ms),
/// `open_and_type` (`text`: in ONE main-actor turn, the New Tab Page action
/// on the focused pane of the first window, then each character as a
/// key-down through `debug.key`'s dispatch, so no key can arrive before the
/// page; returns the opening), `field` (the focused pane's new tab field:
/// its text and whether it has focus), `retarget` (park the spare in window
/// `window`, as a key-window change does). `window` (an index into the main
/// windows, default 0) picks the window for `open_and_type` and `field`.
@MainActor
enum DebugNewTab {
    static func handle(_ params: [String: JSONValue], _ services: AppServices?) async -> JSONValue {
        guard let services else { return .null }
        switch params["action"]?.stringValue ?? "state" {
        case "state":
            return state(services)
        case "open_and_type":
            return openAndType(params, services: services)
        case "field":
            return await field(params, services)
        case "retarget":
            // What a key-window change does, for no-activate runs whose windows never become key.
            guard let window = controller(params, services)?.window else { return .object(["error": .string("no such window")]) }
            services.newTabSpares.retarget(window)
            return state(services)
        default:
            return .object(["error": .string("unknown action; use state, open_and_type or field")])
        }
    }

    private static func state(_ services: AppServices) -> JSONValue {
        let pool = services.newTabSpares
        var spares: [JSONValue] = []
        if let spare = pool.spare {
            // Ready: the page asked for its handshake, so it is loaded and rendered.
            var entry: [String: JSONValue] = ["window": .number(Double(spare.window)), "ready": .bool(spare.view.model.hasHandshake)]
            if let pid = webProcess(spare.view.webView) {
                entry["pid"] = .number(Double(pid))
                entry["footprint_mb"] = footprint(pid).map { .number($0) } ?? .null
            }
            spares.append(.object(entry))
        }
        return .object([
            "likely": .bool(pool.isLikely), "spares": .array(spares), "openings": .array(pool.openings.map(opening)),
            "target_window": pool.target.map { .number(Double($0.windowNumber)) } ?? .null,
            "last_retarget_ms": pool.lastRetargetMilliseconds.map { .number($0) } ?? .null,
        ])
    }

    private static func opening(_ opening: NewTabSparePool.Opening) -> JSONValue {
        .object(["spare": .bool(opening.spare), "cross_window": .bool(opening.crossWindow), "ms": .number(opening.milliseconds)])
    }

    /// The window `index` (`window` param, an index into the main windows), else the first.
    private static func controller(_ params: [String: JSONValue], _ services: AppServices) -> WindowController? {
        let controllers = services.windows.controllers
        let index = params["window"]?.intValue ?? 0
        return controllers.indices.contains(index) ? controllers[index] : nil
    }

    private static func openAndType(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let text = params["text"]?.stringValue ?? ""
        let target = controller(params, services)
        guard let pane = target?.content?.focusedPane else {
            return .object(["error": .string("no focused pane")])
        }
        pane.newTabPage()
        // Where the first key goes: the adopted page's web view, or a stale responder.
        let responder = pane.view.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        for character in text {
            var key: [String: JSONValue] = ["key": .string(String(character))]
            if let id = target?.state.id { key["window"] = .string(id) }
            _ = DebugKey.send(key, services: services)
        }
        return .object([
            "opening": services.newTabSpares.openings.last.map(opening) ?? .null,
            "first_responder": .string(responder),
        ])
    }

    private static func field(_ params: [String: JSONValue], _ services: AppServices) async -> JSONValue {
        guard let pane = controller(params, services)?.content?.focusedPane, let key = pane.currentTabKey,
              let view = services.agentTabs.existingView(key) else {
            return .object(["error": .string("the focused pane shows no agent page")])
        }
        let script = """
            const field = document.querySelector('.nt-field, .acpmux-newtab-field');
            return JSON.stringify({ text: field ? field.value : null, focused: !!field && document.activeElement === field });
            """
        guard let text = try? await view.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let value = JSONValue(foundation: object) else {
            return .object(["error": .string("the page returned no JSON")])
        }
        return value
    }

    private static func webProcess(_ webView: WKWebView) -> Int32? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    /// Physical footprint in MB (what Activity Monitor's Memory column shows).
    private static func footprint(_ pid: Int32) -> Double? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : nil
    }
}
#endif
