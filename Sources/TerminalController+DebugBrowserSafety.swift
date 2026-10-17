#if DEBUG
import AppKit
import CmuxBrowser
import CmuxCEF
import CmuxCEFBrowser
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
        case "debug.browser.chromium_extension_ui":
            return debugChromiumExtensionUI(params: params)
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
        case .chromiumLoadFailed: "load_failed"
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
                case ("reload", "load_failed"):
                    panel.performPageRecovery(prompt)
                    pressed = true
                case ("proceed", "load_failed") where panel.canProceedPastChromiumLoadFailure:
                    // The recovery view's Proceed button, for tests (DEBUG builds only).
                    panel.proceedPastChromiumLoadFailure()
                    pressed = true
                default:
                    break
                }
            }
            // The Back/Forward history menus' entries, and one chosen as the menu would.
            if case .int(let offset)? = params["go_to_entry"] {
                panel.goToBackForwardEntry(offset: Int(offset))
                pressed = true
            }
            let historyMenu: (Bool) -> [Any] = { forward in
                panel.backForwardMenuEntries(forward: forward).map { entry in
                    ["offset": entry.offset, "title": self.v2OrNull(entry.title), "url": self.v2OrNull(entry.url?.absoluteString)] as [String: Any]
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
                "load_error": v2OrNull(panel.chromiumLoadFailure?.error.name),
                "can_proceed": panel.canProceedPastChromiumLoadFailure,
                "back_menu": historyMenu(false),
                "forward_menu": historyMenu(true),
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

    /// Results of `omnibox_action: "suggest"` by panel, read by a later call.
    private static var debugOmniboxSuggestions: [UUID: [String]] = [:]

    /// `debug.browser.chromium_extension_ui`: extension-facing Chromium UI of
    /// a panel for dogfood scripts. Reports extension popup windows
    /// (`chrome.windows.create`), the side panel header cmux draws, and the
    /// panel's omnibox keywords. `side_panel_press` runs a header control;
    /// `omnibox_text` with `omnibox_action` (`update`, `suggest`, `enter`)
    /// drives the address bar's keyword session as typing would.
    private func debugChromiumExtensionUI(params: [String: JSONValue]) -> ControlCallResult {
        func string(_ key: String) -> String? {
            if case .string(let text)? = params[key] { return text }
            return nil
        }
        let result = v2BrowserWithPanel(params: params.mapValues(\.foundationObject)) { workspaceId, surfaceId, panel in
            let runtime = CEFRuntime.shared
            let popupWindows: [[String: Any]] = runtime.liveBrowsers.compactMap { browser in
                guard let window = browser.popupWindow else { return nil }
                return [
                    "browser": Int(browser.browserID ?? 0), "window": Int(window),
                    "url": v2OrNull(browser.state.url?.absoluteString), "title": browser.state.title,
                    "shown": browser.hostView.window != nil,
                ]
            }
            let popupPanels: [[String: Any]] = NSApp.windows
                .filter { $0.identifier?.rawValue == "cmux.browser-popup" && $0.isVisible }
                .map { ["title": $0.title, "frame": NSStringFromRect($0.frame)] }
            var payload: [String: Any] = [
                "workspace_id": workspaceId.uuidString,
                "surface_id": surfaceId.uuidString,
                "engine": panel.engineKind.rawValue,
                "fork_api": Int(runtime.forkAPIVersion),
                "popup_window_log": runtime.popupWindowLog,
                "popup_window_pages": popupWindows,
                "popup_panels": popupPanels,
            ]
            if let page = panel.enginePage as? CEFBrowserPage {
                var pressed: Bool?
                if let control = string("side_panel_press").flatMap(ChromiumSidePanelControl.init(rawValue:)) {
                    pressed = page.sidePanel.press(control)
                }
                page.sidePanel.refresh()
                if let state = page.sidePanel.state, let header = page.sidePanel.header {
                    payload["side_panel"] = [
                        "title": state.title,
                        "controls": state.visibleControls.map(\.rawValue),
                        "pinned": state.isPinned,
                        "chromium_focusable_controls": v2OrNull(state.chromiumFocusableControls),
                        "header_frame": NSStringFromRect(header.frame),
                        "hole": v2OrNull(page.browser.hostView.sidePanelHeaderRect.map { NSStringFromRect($0) }),
                        "header_in_window": header.window != nil,
                    ] as [String: Any]
                } else {
                    payload["side_panel"] = NSNull()
                }
                payload["side_panel_pressed"] = v2OrNull(pressed)
            }
            let provider = panel.omniboxKeywordProvider
            payload["omnibox_keywords"] = (provider?.omniboxKeywords() ?? []).map {
                ["extension_id": $0.extensionID, "keyword": $0.keyword, "name": $0.name]
            }
            if let text = string("omnibox_text") {
                let session = panel.omniboxKeywordSession
                switch string("omnibox_action") ?? "update" {
                case "enter":
                    payload["omnibox_entered"] = session.enter(text: text, provider: provider)
                case "suggest":
                    if let provider, let match = session.update(text: text, provider: provider) {
                        let panelID = panel.id
                        Self.debugOmniboxSuggestions[panelID] = nil
                        Task { @MainActor in
                            let rows = await provider.omniboxKeywordSuggestions(match.keyword.extensionID, text: match.rest)
                            Self.debugOmniboxSuggestions[panelID] = match.keyword.rows(text: match.rest, suggestions: rows)
                                .map { "\($0.content)|\($0.description)" }
                        }
                    }
                    payload["omnibox_session"] = v2OrNull(session.activeExtensionID)
                default:
                    _ = session.update(text: text, provider: provider)
                    payload["omnibox_session"] = v2OrNull(session.activeExtensionID)
                }
            }
            payload["omnibox_last_suggestions"] = v2OrNull(Self.debugOmniboxSuggestions[panel.id])
            return .ok(payload)
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
