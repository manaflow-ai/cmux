#if DEBUG
import AppKit
import CmuxCloud
import Foundation

/// DEBUG-only socket verbs that open and drive the Cloud UI for dogfood and
/// evaluation without Accessibility or Screen Recording grants:
///
/// - `debug.cloud_secrets.show {machine_id?, machine_label?}`
/// - `debug.cloud_secrets.state`
/// - `debug.cloud_secrets.interact {action, ...}`
/// - `debug.cloud_getting_started.state`
/// - `debug.cloud_getting_started.interact {action: dismiss|press_current|copy_command}`
/// - `debug.cloud_panel.show`
/// - `debug.cloud_first_run.show` / `.state` / `.interact {action, value?}`
///
/// They run on the main-actor lane because every one reads or presents AppKit
/// and SwiftUI model state. Responses carry names and labels, never a secret
/// value. Pair with `debug.window.screenshot` or `cmux shot --window <window_id>`.
extension TerminalController {
    nonisolated static let cloudDebugMethodNames: [String] = [
        "debug.cloud_secrets.show",
        "debug.cloud_secrets.state",
        "debug.cloud_secrets.interact",
        "debug.cloud_getting_started.state",
        "debug.cloud_getting_started.interact",
        "debug.cloud_panel.show",
        "debug.cloud_first_run.show",
        "debug.cloud_first_run.state",
        "debug.cloud_first_run.interact",
    ]

    nonisolated static func isCloudDebugMethod(_ method: String) -> Bool {
        cloudDebugMethodNames.contains(method)
    }

    func v2DebugCloudUI(id: Any?, method: String, params: [String: Any]) -> String {
        switch method {
        case "debug.cloud_secrets.show":
            return v2DebugCloudSecretsShow(id: id, params: params)
        case "debug.cloud_secrets.state":
            return v2Ok(id: id, result: v2DebugCloudSecretsState())
        case "debug.cloud_secrets.interact":
            return v2DebugCloudSecretsInteract(id: id, params: params)
        case "debug.cloud_getting_started.state":
            let probe = CloudDebugGettingStartedProbe.shared
            return v2Ok(id: id, result: CloudDebugGettingStartedProbe.state(
                probe.current(keyWindow: NSApp.keyWindow),
                mountedCount: probe.mountedCount
            ))
        case "debug.cloud_getting_started.interact":
            return v2DebugCloudGettingStartedInteract(id: id, params: params)
        case "debug.cloud_panel.show":
            return v2DebugCloudPanelShow(id: id)
        case "debug.cloud_first_run.show", "debug.cloud_first_run.state", "debug.cloud_first_run.interact":
            return v2DebugCloudFirstRun(id: id, method: method, params: params)
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    // MARK: Cloud Secrets

    private func v2DebugCloudSecretsShow(id: Any?, params: [String: Any]) -> String {
        let machineID = CloudDebugSecretsProbe.string(params, "machine_id")
        let machineLabel = CloudDebugSecretsProbe.string(params, "machine_label")
        let preferred = NSApp.keyWindow ?? NSApp.mainWindow
        // The same call the Get started card and machine menus make.
        CloudSecretsSheetPresenter.shared.present(
            machineID: machineID,
            machineLabel: machineLabel,
            preferredWindow: preferred
        )
        guard let sheet = CloudSecretsSheetPresenter.shared.debugOpenSheet else {
            return v2Ok(id: id, result: ["presented": false])
        }
        var result: [String: Any] = [
            "presented": true,
            "attached": sheet.host != nil,
            "sheet_window_number": sheet.window.windowNumber,
        ]
        result["machine_id"] = machineID
        let host = sheet.host ?? preferred
        if let host,
           let tabManager = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: host),
           let windowID = AppDelegate.shared?.windowId(for: tabManager) {
            result["window_id"] = windowID.uuidString
            result["window_ref"] = v2Ref(kind: .window, uuid: windowID)
        }
        return v2Ok(id: id, result: result)
    }

    private func v2DebugCloudSecretsState() -> [String: Any] {
        guard let sheet = CloudSecretsSheetPresenter.shared.debugOpenSheet else {
            return ["open": false]
        }
        return CloudDebugSecretsProbe.state(sheet.model, busy: CloudDebugSecretsProbe.inFlightActions > 0)
    }

    private func v2DebugCloudSecretsInteract(id: Any?, params: [String: Any]) -> String {
        let action: CloudDebugSecretsProbe.Action
        switch CloudDebugSecretsProbe.parseAction(params) {
        case .success(let parsed): action = parsed
        case .failure(let error): return v2Error(id: id, code: "invalid_params", message: error.message)
        }
        guard let model = CloudSecretsSheetPresenter.shared.debugOpenSheet?.model else {
            return v2Error(id: id, code: "not_found", message: "Cloud Secrets sheet is not open; call debug.cloud_secrets.show first")
        }
        if let outcome = CloudDebugSecretsProbe.performSync(action, on: model) {
            return v2DebugCloudOutcome(id: id, action: action.name, outcome: outcome)
        }
        if let refusal = CloudDebugSecretsProbe.preflight(action, on: model) {
            return v2DebugCloudOutcome(id: id, action: action.name, outcome: refusal)
        }
        // The model's async methods await the vault; the socket must not hold
        // the main actor for them. Poll `debug.cloud_secrets.state` until busy is false.
        CloudDebugSecretsProbe.inFlightActions += 1
        Task { @MainActor in
            _ = await CloudDebugSecretsProbe.perform(action, on: model)
            CloudDebugSecretsProbe.inFlightActions -= 1
        }
        return v2Ok(id: id, result: ["action": action.name, "started": true, "busy": true])
    }

    private func v2DebugCloudOutcome(id: Any?, action: String, outcome: CloudDebugSecretsProbe.Outcome) -> String {
        switch outcome {
        case .applied:
            return v2Ok(id: id, result: ["action": action, "applied": true])
        case .ignored(let reason):
            return v2Ok(id: id, result: ["action": action, "applied": false, "reason": reason])
        case .notFound(let reason):
            return v2Error(id: id, code: "not_found", message: reason)
        }
    }

    // MARK: Getting started

    private func v2DebugCloudGettingStartedInteract(id: Any?, params: [String: Any]) -> String {
        guard let raw = CloudDebugSecretsProbe.string(params, "action"),
              let action = CloudDebugGettingStartedProbe.Action(rawValue: raw) else {
            let names = CloudDebugGettingStartedProbe.Action.allCases.map(\.rawValue).joined(separator: ", ")
            return v2Error(id: id, code: "invalid_params", message: "action must be one of \(names)")
        }
        guard let entry = CloudDebugGettingStartedProbe.shared.current(keyWindow: NSApp.keyWindow) else {
            return v2Error(id: id, code: "not_found", message: "Cloud panel is not mounted; call debug.cloud_panel.show first")
        }
        let actions = entry.actions()
        let step = entry.checklist.current
        switch action {
        case .dismiss:
            actions.dismiss()
            return v2Ok(id: id, result: ["action": action.rawValue, "applied": true])
        case .pressCurrent:
            guard entry.checklist.isVisible else {
                return v2Ok(id: id, result: ["action": action.rawValue, "applied": false, "reason": "the card is hidden"])
            }
            let press = CloudDebugGettingStartedProbe.press(for: step, actions: actions)
            switch press {
            case .openSecrets: actions.openSecrets?()
            case .createMachine: actions.createMachine()
            case .openLocalAgent: actions.openLocalAgent?()
            case .openRepository: actions.openRepository?()
            case .noButton:
                return v2Ok(id: id, result: ["action": action.rawValue, "applied": false, "reason": "the current step has no button"])
            }
            return v2Ok(id: id, result: ["action": action.rawValue, "applied": true, "pressed": "\(press)", "step": step?.rawValue ?? ""])
        case .copyCommand:
            guard entry.checklist.isVisible,
                  let command = CloudDebugGettingStartedProbe.command(for: step, actions: actions) else {
                return v2Ok(id: id, result: ["action": action.rawValue, "applied": false, "reason": "the current step has no command"])
            }
            // The card's copy button writes the general pasteboard the same way.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
            return v2Ok(id: id, result: ["action": action.rawValue, "applied": true, "command": command])
        }
    }

    // MARK: Cloud panel

    private func v2DebugCloudPanelShow(id: Any?) -> String {
        guard let appDelegate = AppDelegate.shared else {
            return v2Error(id: id, code: "unavailable", message: "AppDelegate not available")
        }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let introduces = appDelegate.cloudCreationGate() == .introduceCloud
        // The sidebar footer Cloud button's action.
        appDelegate.performSidebarCloudButtonAction(preferredWindow: window)
        var result: [String: Any] = [
            "available": CloudMachinesFeature.isAvailable,
            "presented_introduction": CloudMachinesFeature.isAvailable && introduces,
        ]
        if let window,
           let tabManager = appDelegate.activeTabManagerForCommands(preferredWindow: window),
           let windowID = appDelegate.windowId(for: tabManager) {
            result["window_id"] = windowID.uuidString
            result["window_ref"] = v2Ref(kind: .window, uuid: windowID)
        }
        return v2Ok(id: id, result: result)
    }
}
#endif
