import AppKit
import CmuxSwiftRender
import CmuxSwiftRenderUI
import Foundation

/// Serial lane for in-process `cmux(...)` sidebar actions. Worker-lane methods
/// (browser JS, waits) must run off the main actor: on the main actor they
/// starve SwiftUI and deadlock on a not-yet-mounted webview, which is exactly
/// why they were moved off the main-actor dispatch path. Running the whole
/// action on one serial queue keeps every command in its authored order, so a
/// later command can't finish before an earlier browser navigate/click/wait.
private let cmuxSidebarWorkerQueue = DispatchQueue(label: "com.cmux.sidebar-action-worker")

/// Select-burst coalescing lives in ``SidebarSelectCoalescer``
/// (CmuxSwiftRenderUI), where its FIFO/newest-wins semantics are unit-tested.
private let sidebarSelectCoalescer = SidebarSelectCoalescer()

// The custom-sidebar rendering, interpreter, JSON DSL, resizable split, and
// the file-watching model now live in the `CmuxSwiftRender` (logic) and
// `CmuxSwiftRenderUI` (SwiftUI) packages. The app target keeps only the
// cmux-coupled action dispatch, the one piece that must reach
// `TerminalController`, and injects it into the package's view from
// `ContentView`.

/// Builds the action sink that runs interpreted sidebar buttons against the
/// live cmux command dispatcher.
///
/// `cmux(...)` commands run in-process through
/// `TerminalController.handleSocketLine(_:)` (the same worker-aware surface the
/// socket CLI uses); `log` is a debug-only no-op for now.
@MainActor
func makeCmuxSidebarActionDispatch() -> SidebarActionDispatch {
    SidebarActionDispatch { action in
        // Capture the controller on the main actor, then run the whole command
        // sequence on the serial worker queue so the commands keep their authored
        // order. handleSocketLine runs worker-lane methods (browser JS, waits) on
        // this thread and hops main-actor methods back to the main actor itself,
        // so nothing here blocks SwiftUI and ordering is preserved end to end.
        let controller = TerminalController.shared
        let commands = action.commands
        let selectGeneration = sidebarSelectCoalescer.generation(for: commands)
        let jsonParameterNames: Set<String> = [
            "layout", "workspace_env", "initial_env", "env", "workspace_ids",
            "child_workspace_ids", "surface_ids", "ids",
        ]
        let booleanParameterNames: Set<String> = [
            "focus", "select", "open", "enabled", "clear", "dry_run", "base",
            "eager_load_terminal", "auto_refresh_metadata",
        ]
        let integerParameterNames: Set<String> = [
            "index", "to_index", "priority", "port", "amount", "count", "limit",
            "offset", "row", "column", "width", "height",
        ]
        cmuxSidebarWorkerQueue.async {
            // A newer select is already queued behind this one: skip the heavy
            // switch, the burst's final click defines the end state.
            if let selectGeneration, !sidebarSelectCoalescer.isCurrent(selectGeneration) {
                return
            }
            for command in commands {
                switch command {
                case let .cmux(method, params):
                    var payload: [String: Any] = ["method": method, "id": UUID().uuidString]
                    if !params.isEmpty {
                        // Params arrive as strings; coerce integer-looking values
                        // (e.g. a reorder `index`) to numbers so typed v2 params
                        // like v2Int decode them.
                        var typed: [String: Any] = [:]
                        for (key, value) in params {
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if (jsonParameterNames.contains(key) || trimmed.hasPrefix("[")),
                               let data = trimmed.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) {
                                // Structured values (layout, environment maps,
                                // and id arrays) travel through the interpreter's
                                // string-only action IR as JSON and are restored
                                // before entering the shared socket path.
                                typed[key] = json
                            } else if booleanParameterNames.contains(key),
                                      let boolValue = Bool(trimmed.lowercased()) {
                                typed[key] = boolValue
                            } else if integerParameterNames.contains(key),
                                      let intValue = Int(trimmed) {
                                typed[key] = intValue
                            } else {
                                typed[key] = value
                            }
                        }
                        payload["params"] = typed
                    }
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let line = String(data: data, encoding: .utf8) else { continue }
                    let response = controller.handleSocketLine(line)
                    guard let responseData = response.data(using: .utf8),
                          let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                        continue
                    }
                    let error: [String: Any]
                    if (envelope["ok"] as? Bool) == false {
                        error = envelope["error"] as? [String: Any] ?? [:]
                    } else if method == "workspace.create",
                              let result = envelope["result"] as? [String: Any],
                              let delivery = result["command_delivery"] as? [String: Any],
                              (delivery["accepted"] as? Bool) == false {
                        // workspace.create commits the workspace even when its
                        // secondary terminal-input delivery fails. Surface that
                        // nested failure through the same sidebar diagnostic
                        // channel as an ordinary rejected command.
                        error = delivery["error"] as? [String: Any]
                            ?? ["code": "command_delivery_failed"]
                    } else {
                        continue
                    }
                    var diagnostic: [String: Any] = [
                        "method": method,
                        "code": error["code"] as? String ?? "command_failed",
                    ]
                    if let message = error["message"] as? String {
                        diagnostic["message"] = message
                    }
                    if let errorData = error["data"] as? [String: Any],
                       let unsupported = errorData["unsupported_param"] as? String {
                        diagnostic["unsupported_param"] = unsupported
                    }
                    CmuxEventBus.shared.publish(
                        name: "sidebar.action.failed",
                        category: "sidebar",
                        source: "custom-sidebar",
                        payload: diagnostic
                    )
                case let .openURL(urlString):
                    // NSWorkspace.open is main-only; run it synchronously to keep the
                    // command's position in the sequence.
                    if let url = URL(string: urlString) {
                        DispatchQueue.main.sync { _ = NSWorkspace.shared.open(url) }
                    }
                case .log:
                    break
                }
            }
        }
    }
}
