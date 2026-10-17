#if DEBUG
import AppKit
import CmuxBrowser
import CmuxControlSocket
import Foundation
import WebKit

/// `debug.browser.crashes` and `debug.browser.page_status`: what crash-injection
/// tests (`tests_v2/test_browser_crash_injection.py`) read after they end a
/// browser content process, and the Reload they press. DEBUG builds only.
@MainActor
extension TerminalController {
    func controlDebugBrowserSafety(method: String, params: [String: JSONValue]) -> ControlCallResult {
        switch method {
        case "debug.browser.crashes":
            return .ok(Self.debugBrowserCrashesPayload(BrowserCrashLog.app))
        case "debug.browser.page_status":
            return debugBrowserPageStatus(params: params)
        case "debug.browser.extension_prompts":
            return .ok(Self.debugExtensionPrompts(params: params, dialogs: .app))
        default:
            return .err(code: "method_not_found", message: "Unknown method", data: nil)
        }
    }

    /// `debug.browser.extension_prompts`: the extension sheets on screen
    /// (Web Store install, `chrome.permissions`, CLI consent). `{}` lists
    /// them; `{id, answer: "accept" | "cancel"}` answers one as its buttons do.
    static func debugExtensionPrompts(params: [String: JSONValue], dialogs: BrowserExtensionOpenDialogs) -> JSONValue {
        if case .int(let id)? = params["id"], case .string(let answer)? = params["answer"] {
            return .object(["ok": .bool(dialogs.answer(Int(id), accepted: answer == "accept"))])
        }
        return .object(["prompts": .array(dialogs.waiting.map { dialog in
            .object([
                "id": .int(Int64(dialog.id)),
                "title": .string(dialog.title),
                "target": .string(dialog.target),
                "extension_id": dialog.targetDetail.map(JSONValue.string) ?? .null,
                "accept_title": .string(dialog.acceptTitle),
                "automation": .bool(dialog.isAutomation),
            ])
        })])
    }

    static func debugBrowserCrashesPayload(_ log: BrowserCrashLog) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        let records: [JSONValue] = log.records.map { record in
            .object([
                "date": .string(formatter.string(from: record.date)),
                "process_type": .string(record.processType),
                "sub_type": record.subType.map(JSONValue.string) ?? .null,
                "pid": record.pid.map { .int(Int64($0)) } ?? .null,
                "kind": .string(String(describing: record.kind)),
                "code": record.codeDescription.map(JSONValue.string) ?? .null,
                "panel_id": record.panelID.map { .string($0.uuidString) } ?? .null,
                "source": .string(record.source.rawValue),
            ])
        }
        return .object(["total": .int(Int64(log.total)), "records": .array(records)])
    }

    /// The prompt's name for tests: Chromium and WebKit crashes are both
    /// "crashed", so one test step covers either engine.
    static func debugPromptName(_ prompt: BrowserPageRecoveryPrompt) -> String {
        switch prompt {
        case .crashed, .chromiumCrashed: "crashed"
        case .chromiumUnresponsive: "unresponsive"
        case .unloaded: "unloaded"
        default: "other"
        }
    }

    private func debugBrowserPageStatus(params: [String: JSONValue]) -> ControlCallResult {
        let press = params["press"].flatMap { value -> String? in
            if case .string(let text) = value { return text }
            return nil
        }
        let result = v2BrowserWithPanel(params: params.mapValues(\.foundationObject)) { workspaceId, surfaceId, panel in
            var pressed = false
            if let prompt = panel.pageRecoveryPrompt {
                switch (press ?? "", Self.debugPromptName(prompt)) {
                case ("reload", "crashed"), ("wait", "unresponsive"):
                    panel.performPageRecovery(prompt)
                    pressed = true
                case ("exit", "unresponsive"):
                    panel.exitUnresponsiveChromiumPage()
                    pressed = true
                default:
                    break
                }
            }
            let promptName = panel.pageRecoveryPrompt.map(Self.debugPromptName)
            let pagePID = panel.debugPageProcessIdentifier
            return .ok([
                "workspace_id": workspaceId.uuidString,
                "surface_id": surfaceId.uuidString,
                "engine": panel.engineKind.rawValue,
                // Where native UI covers a Chromium page (crash page, hang card, find bar): the
                // page window leaves these holes so the overlay shows above it.
                "occlusion_rects": ((panel.enginePage as? any BrowserPageOcclusionHosting)?.pageOcclusionRects ?? [])
                    .map { NSStringFromRect($0) },
                "floating_overlays_in_panels": panel.pageOverlays.hostsFloatingOverlaysInPanels,
                "page_pid": pagePID,
                "prompt": v2OrNull(promptName),
                "crashed": promptName == "crashed",
                "pressed": pressed,
                "current_url": v2OrNull(panel.currentURL?.absoluteString),
            ])
        }
        switch result {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }
}
#endif
