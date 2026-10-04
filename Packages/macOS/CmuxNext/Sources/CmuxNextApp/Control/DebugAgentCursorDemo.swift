#if DEBUG
import CmuxNextAgentCursor
import CmuxNextSettings
import Foundation

/// `debug.agent_cursor.demo` (DEBUG builds only): drives the REAL agent
/// cursor stacks with scripted input, so a visual check covers the real
/// layers, z-order, coordinates and visibility rules.
///
/// Params: `action` (move, click, double_click, right_click, type, key,
/// pause, resume, takeover, end, report), `target` (a browser tab id),
/// `session` (default "demo"), `x`/`y` (viewport CSS px), `zoom`.
/// Input goes to the shown content of every window (each resolves the
/// target; only the window that shows it draws); lease actions go to every
/// content. One call is one step: the caller paces the steps, so the app
/// runs no timer. Every reply reports each window's cursor layers.
@MainActor
enum DebugAgentCursorDemo {
    private static var demo = AgentCursorDemo()

    static func handle(_ params: [String: CmuxNextSettings.JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        let action = params["action"]?.stringValue ?? "report"
        var result: [String: CmuxNextSettings.JSONValue] = ["action": .string(action)]
        if action != "report" {
            guard let target = params["target"]?.stringValue, !target.isEmpty else {
                return .object(["error": .string("target (a browser tab id) is required")])
            }
            let session = params["session"]?.stringValue ?? "demo"
            do {
                let step = try demo.step(
                    action: action, session: session, target: target,
                    x: params["x"]?.doubleValue, y: params["y"]?.doubleValue, zoom: params["zoom"]?.doubleValue,
                    tMs: Date().timeIntervalSince1970 * 1000
                )
                apply(step, services: services)
            } catch {
                result["error"] = .string(String(describing: error))
            }
        }
        result["windows"] = .array(report(services))
        return .object(result)
    }

    private static func apply(_ step: AgentCursorDemo.Step, services: AppServices) {
        let controllers = services.windows.controllers
        switch step {
        case let .input(event):
            for controller in controllers {
                controller.content?.agentCursor?.publisher.publish(event)
            }
        case let .lease(session, state):
            for controller in controllers {
                for content in controller.parked + [controller.content].compactMap({ $0 }) {
                    content.agentCursor?.model.leaseDidChange(session: session, state: state)
                    if state == nil { content.agentCursor?.publisher.endSession(session) }
                }
            }
        }
    }

    private static func report(_ services: AppServices) -> [CmuxNextSettings.JSONValue] {
        services.windows.controllers.map { controller in
            var cursors: [CmuxNextSettings.JSONValue] = []
            if let host = controller.content?.agentCursor?.host {
                for session in host.sessions {
                    guard let cursor = host.cursorLayer(for: session) else { continue }
                    let position = cursor.root.position
                    cursors.append(.object([
                        "session": .string(session),
                        "x": .number(Double(position.x)),
                        "y": .number(Double(position.y)),
                        "hidden": .bool(cursor.root.isHidden),
                        "paused": .bool(cursor.isPaused),
                        "indicator": .bool(cursor.showsIndicator),
                        "animations": .array((cursor.root.animationKeys() ?? []).map { .string($0) }),
                    ]))
                }
            }
            return .object(["window": .string(controller.state.id), "cursors": .array(cursors)])
        }
    }
}
#endif
