public import CmuxNextControl
public import CmuxNextSettings
import Foundation

/// `agent.chat.perf` on the app control socket (`cmux app chat perf --tab <tab> --seconds <S>`,
/// every build, Release and Nightly too): runs the chat page's own capture
/// (`window.cmuxAcpmuxBridge.perfCapture`, webviews chatPerfCapture.ts) for `seconds` (1 to 60,
/// default 5) and returns its JSON: frames, long tasks, layout shift, and each arriving record's
/// time to paint. Read-only: it never focuses, selects, shows, un-occludes or thaws the tab, so a covered
/// or hidden chat reports that it drew nothing rather than numbers nobody saw, and a frozen one is refused. The page's
/// observers exist only for the capture. The App only finds the tab's existing page (`find`).
public struct AgentChatPerfControl: Sendable {
    public nonisolated static let method = "agent.chat.perf"
    public nonisolated static let maxSeconds = 60
    public nonisolated static let defaultSeconds = 5

    /// What the App found for a tab id, without focusing, showing or loading anything.
    public enum ChatPage {
        case missing
        case notAgentChat
        case notLoaded
        case page(AgentPaneView)
    }

    /// Looks the (normalized) tab id up in the App's tabs.
    let find: @MainActor @Sendable (String) -> ChatPage

    public init(find: @escaping @MainActor @Sendable (String) -> ChatPage) {
        self.find = find
    }

    /// The App's control service registers this (`AppControl`).
    public func controlMethod() -> ControlMethod {
        let find = find
        return .async(Self.method) { call in try await Self.run(call.params, find: find) }
            .withDeadline(.fixed(.seconds(Self.maxSeconds + 15)))
            .withLimit { request, _ in .seconds(((try? Self.seconds(request.params)) ?? Self.maxSeconds) + 15) }
    }

    /// `seconds`, checked: a whole number from 1 to 60, or absent for the default.
    public nonisolated static func seconds(_ params: [String: JSONValue]) throws -> Int {
        guard let raw = params["seconds"] else { return defaultSeconds }
        guard let value = raw.doubleValue, value.rounded() == value, value >= 1, value <= Double(maxSeconds) else {
            throw ControlError.invalidParams(String(format: Text.seconds, maxSeconds))
        }
        return Int(value)
    }

    /// The page call: the capture's JSON as text, or an error object when the page has no capture.
    static let script = """
        const bridge = window.cmuxAcpmuxBridge;
        if (typeof bridge?.perfCapture !== "function") return JSON.stringify({ error: "no_capture" });
        return JSON.stringify(await bridge.perfCapture({ seconds }));
        """

    /// On the main actor: the tab is found, and a frozen page refused, in the same turn that sends the call.
    @MainActor
    static func run(_ params: [String: JSONValue], find: @MainActor @Sendable (String) -> ChatPage) async throws -> JSONValue {
        let seconds = try seconds(params)
        guard let raw = params["tab"]?.stringValue, !raw.isEmpty else {
            throw ControlError.invalidParams(Text.needsTab)
        }
        let tabID = normalizedControlTabID(raw)
        let view: AgentPaneView
        switch find(tabID) {
        case .missing: throw ControlError(code: "not_found", message: Text.noTab)
        case .notAgentChat: throw ControlError.invalidParams(Text.notAgentChat)
        case .notLoaded: throw ControlError(code: "unavailable", message: Text.pageNotLoaded)
        case .page(let page): view = page
        }
        // A hidden page the app froze runs no script, and any call would thaw it first: measuring
        // must not wake it, and a frozen page has no frames to report.
        guard !view.pageIsFrozen else { throw ControlError(code: "unavailable", message: Text.pageAsleep) }
        // The capture awaits for `seconds` on purpose: Chromium's DevTools call would give up after
        // its 5 s default, so it gets the capture's length and a margin (the control's own limit is +15 s).
        let result = try await view.callPageScript(script, arguments: ["seconds": seconds], timeout: .seconds(seconds + 10))
        guard let text = result as? String, case .object(var report)? = try? JSONValue.parse(Data(text.utf8)) else {
            throw ControlError(code: "unavailable", message: Text.noCapture)
        }
        switch report["error"]?.stringValue {
        case "capture_running"?: throw ControlError(code: "conflict", message: Text.running)
        case .some: throw ControlError(code: "unavailable", message: Text.noCapture)
        case nil: break
        }
        report["tab"] = .string(tabID)
        return .object(report)
    }

    /// The refusals, in this package's Localizable.xcstrings (`agentPane.chatPerf.*`).
    nonisolated enum Text {
        static var seconds: String { String(localized: "agentPane.chatPerf.seconds", defaultValue: "seconds must be a whole number from 1 to %lld", bundle: .module) }
        static var needsTab: String { String(localized: "agentPane.chatPerf.needsTab", defaultValue: "Name the chat tab to measure.", bundle: .module) }
        static var noTab: String { String(localized: "agentPane.chatPerf.noTab", defaultValue: "That tab is no longer open.", bundle: .module) }
        static var notAgentChat: String { String(localized: "agentPane.chatPerf.notAgentChat", defaultValue: "That tab isn't an agent chat.", bundle: .module) }
        static var pageNotLoaded: String {
            String(localized: "agentPane.chatPerf.pageNotLoaded", defaultValue: "That chat's page isn't loaded. Open the chat once, then measure it again.", bundle: .module)
        }
        static var pageAsleep: String {
            String(
                localized: "agentPane.chatPerf.pageAsleep",
                defaultValue: "That chat's page is asleep while it's hidden, and measuring doesn't wake it. Show the chat, then measure it again.",
                bundle: .module)
        }
        static var noCapture: String {
            String(localized: "agentPane.chatPerf.noCapture", defaultValue: "That chat's page can't measure itself. Update cmux, then try again.", bundle: .module)
        }
        static var running: String {
            String(localized: "agentPane.chatPerf.running", defaultValue: "That chat is already being measured. Try again when that capture ends.", bundle: .module)
        }
    }
}
