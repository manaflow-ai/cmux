import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 debug text box methods
extension TerminalController {
#if DEBUG
    func v2DebugTextBoxInlineFixture(params: [String: Any]) -> V2CallResult {
        guard let tabManager else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let rawPathValue = params["path"] as? String
        let rawPath = rawPathValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawPathValue, rawPathValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(code: "invalid_params", message: "path cannot be empty", data: nil)
        }
        let hasAttachment = rawPath?.isEmpty == false
        let beforeText = (params["before_text"] as? String) ?? (hasAttachment ? "hello " : "")
        let afterText = (params["after_text"] as? String) ?? (hasAttachment ? "world" : "")
        let rawSurfaceID = params["surface_id"] as? String
        let target = rawSurfaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawSurfaceID,
           rawSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(code: "invalid_params", message: "surface_id cannot be empty", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Terminal panel not found", data: nil)
        v2MainSync {
            let panel: TerminalPanel?
            if let target, !target.isEmpty {
                panel = resolveTerminalPanel(from: target, tabManager: tabManager)
            } else {
                panel = tabManager.selectedTerminalPanel
            }

            guard let panel else {
                return
            }

            let url = rawPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            _ = panel.installDebugTextBoxInlineFixture(
                localURL: url,
                beforeText: beforeText,
                afterText: afterText
            )
            let textView = panel.textBoxInputView
            result = .ok([
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "path": url?.path ?? "",
                "text_box_active": panel.isTextBoxActive,
                "has_text_view": textView != nil,
                "text_view_has_window": textView?.window != nil,
                "text_view_matches_panel_window": textView?.window === panel.hostedView.window,
                "panel_text": panel.textBoxContent,
                "panel_attachment_count": panel.textBoxAttachments.count,
                "text_view_text": textView?.plainText() ?? "",
                "text_view_attachment_count": textView?.inlineAttachments().count ?? 0
            ])
        }
        return result
    }

    func v2DebugTextBoxInteract(params: [String: Any]) -> V2CallResult {
        guard let tabManager else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2String(params, "action")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !action.isEmpty else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }
        let rawSurfaceID = params["surface_id"] as? String
        let target = rawSurfaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawSurfaceID,
           rawSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .err(code: "invalid_params", message: "surface_id cannot be empty", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Terminal text box not found", data: nil)
        v2MainSync {
            let panel: TerminalPanel?
            if let target, !target.isEmpty {
                panel = resolveTerminalPanel(from: target, tabManager: tabManager)
            } else {
                panel = tabManager.selectedTerminalPanel
            }

            guard let panel,
                  let textView = panel.textBoxInputView,
                  let window = textView.window else {
                return
            }

            if socketCommandAllowsInAppFocusMutations() {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            let state = textView.debugInteract(action: action)
            result = .ok([
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "action": action,
                "state": state
            ])
        }
        return result
    }
#endif
}
