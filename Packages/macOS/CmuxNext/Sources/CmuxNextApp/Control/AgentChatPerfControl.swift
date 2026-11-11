import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextDaemonService
import CmuxNextSettings
import Foundation

/// `agent.chat.perf` on the app control socket (`cmux app chat perf --tab <tab> --seconds <S>`,
/// every build, Release and Nightly too): runs the chat page's own capture
/// (`window.cmuxAcpmuxBridge.perfCapture`, webviews chatPerfCapture.ts) for `seconds` (1 to 60,
/// default 5) and returns its JSON: frames, long tasks, layout shift, and each arriving record's
/// time to paint. Read-only: it never focuses, selects, shows or un-occludes the tab, so a covered
/// or hidden chat reports that it drew nothing rather than numbers nobody saw. The page's
/// observers exist only for the capture.
@MainActor
enum AgentChatPerfControl {
    nonisolated static let method = "agent.chat.perf"
    nonisolated static let maxSeconds = 60
    nonisolated static let defaultSeconds = 5

    static func controlMethod(_ services: AppServices) -> ControlMethod {
        .async(method) { [weak services] call in
            let services = await MainActor.run { services }
            return try await run(call.params, services: services)
        }
        .withDeadline(.fixed(.seconds(maxSeconds + 15)))
        .withLimit { request, _ in .seconds(((try? seconds(request.params)) ?? maxSeconds) + 15) }
    }

    /// `seconds`, checked: a whole number from 1 to 60, or absent for the default.
    nonisolated static func seconds(_ params: [String: JSONValue]) throws -> Int {
        guard let raw = params["seconds"] else { return defaultSeconds }
        guard let value = raw.doubleValue, value.rounded() == value, value >= 1, value <= Double(maxSeconds) else {
            throw ControlError.invalidParams(RefusalStrings.chatPerfSeconds(maxSeconds))
        }
        return Int(value)
    }

    /// The page call: the capture's JSON as text, or an error object when the page has no capture.
    static let script = """
        const bridge = window.cmuxAcpmuxBridge;
        if (typeof bridge?.perfCapture !== "function") return JSON.stringify({ error: "no_capture" });
        return JSON.stringify(await bridge.perfCapture({ seconds }));
        """

    static func run(_ params: [String: JSONValue], services: AppServices?) async throws -> JSONValue {
        guard let services else { throw ControlError(code: "unavailable", message: RefusalStrings.noWindowShowsWorkspace) }
        let seconds = try seconds(params)
        guard let raw = params["tab"]?.stringValue, !raw.isEmpty else {
            throw ControlError.invalidParams(RefusalStrings.chatPerfNeedsTab)
        }
        let tabID = ResourceControl.normalizedTabID(raw)
        let view = try chatView(tabID, services: services)
        let result = try await view.callPageScript(script, arguments: ["seconds": seconds])
        guard let text = result as? String, case .object(var report)? = try? JSONValue.parse(Data(text.utf8)) else {
            throw ControlError(code: "unavailable", message: RefusalStrings.chatPerfNoCapture)
        }
        switch report["error"]?.stringValue {
        case "capture_running"?: throw ControlError(code: "conflict", message: RefusalStrings.chatPerfRunning)
        case .some: throw ControlError(code: "unavailable", message: RefusalStrings.chatPerfNoCapture)
        case nil: break
        }
        report["tab"] = .string(tabID)
        return .object(report)
    }

    /// The chat page of tab `id`, found without focusing, selecting, showing or loading anything.
    static func chatView(_ id: String, services: AppServices) throws -> AgentPaneView {
        guard let (tab, _) = services.locateTab(id) else { throw ControlError(code: "not_found", message: RefusalStrings.noTab(id)) }
        guard tab.agentSession != nil else { throw ControlError.invalidParams(RefusalStrings.chatPerfNotAgentChat) }
        guard let tabs = services.madeAgentTabs, let view = tabs.views[tabs.tabKey(of: tab)] else {
            throw ControlError(code: "unavailable", message: RefusalStrings.chatPerfPageNotLoaded)
        }
        return view
    }
}
