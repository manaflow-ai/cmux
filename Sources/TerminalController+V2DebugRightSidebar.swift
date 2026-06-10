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


// MARK: - V2 debug right sidebar methods
extension TerminalController {
#if DEBUG
    func v2DebugRightSidebarFocus(params: [String: Any]) -> V2CallResult {
        let modeName = v2String(params, "mode") ?? RightSidebarMode.dock.rawValue
        guard let mode = RightSidebarMode(rawValue: modeName) else {
            return .err(code: "invalid_params", message: "Invalid right sidebar mode", data: ["mode": modeName])
        }
        let requestedWindowId = v2UUID(params, "window_id")
        let focusFirstItem = v2Bool(params, "focus_first_item") ?? true
        var focused = false
        var focusApplied = false
        var contextFound = false
        var stateFound = false
        var visible = false
        var activeMode: String?
        var missingWindow = false

        let preferredWindow: NSWindow?
        if let requestedWindowId {
            preferredWindow = AppDelegate.shared?.mainWindow(for: requestedWindowId)
            missingWindow = preferredWindow == nil
        } else {
            preferredWindow = NSApp.keyWindow ?? NSApp.mainWindow
        }
        guard !missingWindow else {
            return .err(
                code: "not_found",
                message: "Window not found",
                data: requestedWindowId.map { ["window_id": $0.uuidString, "window_ref": v2Ref(kind: .window, uuid: $0)] }
            )
        }
        let result = AppDelegate.shared?.debugRevealRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: focusFirstItem,
            preferredWindow: preferredWindow
        )
        focused = result?.revealed ?? false
        focusApplied = result?.focusApplied ?? false
        contextFound = result?.contextFound ?? false
        stateFound = result?.stateFound ?? false
        visible = result?.visible ?? false
        activeMode = result?.activeMode

        return .ok([
            "focused": focused,
            "focus_applied": focusApplied,
            "context_found": contextFound,
            "state_found": stateFound,
            "visible": visible,
            "active_mode": v2OrNull(activeMode),
            "mode": mode.rawValue,
            "window_id": v2OrNull(requestedWindowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
        ])
    }

    func debugRightSidebarFocus(_ args: String) -> String {
        let modeName = args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RightSidebarMode.dock.rawValue
            : args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mode = RightSidebarMode(rawValue: modeName) else {
            return "ERROR: Invalid right sidebar mode: \(modeName)"
        }

        var revealed = false
        var focusApplied = false
        var contextFound = false
        var stateFound = false
        var visible = false
        var activeMode = ""

        let result = AppDelegate.shared?.debugRevealRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: false,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
        revealed = result?.revealed ?? false
        focusApplied = result?.focusApplied ?? false
        contextFound = result?.contextFound ?? false
        stateFound = result?.stateFound ?? false
        visible = result?.visible ?? false
        activeMode = result?.activeMode ?? ""

        let details = "mode=\(mode.rawValue) active=\(activeMode) visible=\(visible ? 1 : 0) " +
            "context=\(contextFound ? 1 : 0) state=\(stateFound ? 1 : 0) focus=\(focusApplied ? 1 : 0)"
        return revealed ? "OK: \(details)" : "ERROR: \(details)"
    }
#endif
}
