import AppKit
import CmuxNextSettings
import os

/// Window invariants checked after every membership transition and
/// reported by `debug.windows` (and in `debug.focus`): a window exists only
/// while it owns at least one workspace, every workspace has one window,
/// and controllers match the registry. The only window without a workspace
/// allowed is the unregistered launch window while it shows the daemon's
/// connecting state.
enum WindowInvariants {
    static func problems(_ manager: WindowManager) -> [String] {
        let value = manager.registry.value
        var problems = value.violations()
        for controller in manager.controllers where controller.state.id != manager.launchWindowID {
            let id = controller.state.id
            guard let window = value.window(id) else {
                problems.append("window \(id) is on screen but not registered")
                continue
            }
            if !window.isOpen { problems.append("window \(id) is on screen but closed") }
            if window.workspaceIDs.isEmpty { problems.append("window \(id) has 0 workspaces") }
            if manager.awaitingContent[id] == nil, !window.workspaceIDs.isEmpty, !manager.hasMirroredWorkspace(window) {
                problems.append("window \(id) is presented but none of its workspaces is mirrored")
            }
        }
        for window in value.openWindows where manager.controller(for: window.id) == nil {
            problems.append("open window \(window.id) has no controller")
        }
        return problems
    }

    /// `debug.windows`: every registered window and whether the invariants hold.
    static func report(_ manager: WindowManager) -> JSONValue {
        let value = manager.registry.value
        let problems = problems(manager)
        return .object([
            "windows": .array(value.windows.map { window in
                let controller = manager.controller(for: window.id)
                return .object([
                    "id": .string(window.id),
                    "open": .bool(window.isOpen),
                    "workspaces": .array(window.workspaceIDs.map(JSONValue.string)),
                    "selected": manager.states[window.id]?.workspaceID.map(JSONValue.string) ?? .null,
                    "has_controller": .bool(controller != nil),
                    "visible": .bool(controller?.window?.isVisible ?? false),
                    "awaiting_content": .bool(manager.awaitingContent[window.id] != nil),
                ])
            }),
            "recency": .array(value.recency.map(JSONValue.string)),
            "launch_window": manager.launchWindowID.map(JSONValue.string) ?? .null,
            "controllers": .number(Double(manager.controllers.count)),
            "problems": .array(problems.map(JSONValue.string)),
            "violations_seen": .number(Double(manager.invariantViolations)),
            "consistent": .bool(problems.isEmpty),
        ])
    }

    /// The page fields of one window in `debug.windows`.
    static func pageFields(state: WindowState?, controller: WindowController?) -> [String: JSONValue] {
        [:]
    }

    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.windows")
}
