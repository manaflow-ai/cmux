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

/// Drops superseded workspace selections during a click burst. A switch costs
/// main-actor work (terminal view swap, ~100-250ms measured), so clicking
/// 1-2-3-4 fast serializes four switches and the last click waits for the
/// first three. Only the NEWEST queued select matters: the sidebar already
/// painted each click optimistically, and the intermediate switches were
/// transient states the user has clicked past. Each single-select action gets
/// a generation stamp at enqueue; at run time a stale stamp skips the switch.
/// Actions mixing a select with other commands are never coalesced, so
/// authored command sequences keep their exact semantics.
private final class SidebarSelectCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    func stamp() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latest += 1
        return latest
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == latest
    }
}

private let sidebarSelectCoalescer = SidebarSelectCoalescer()

/// A single-command `workspace.select` action is coalescable; anything else
/// (multi-command sequences, other methods) runs unconditionally.
private func sidebarSelectGeneration(for commands: [ActionCommand]) -> UInt64? {
    guard commands.count == 1,
          case let .cmux(method, _) = commands[0],
          method == "workspace.select" else { return nil }
    return sidebarSelectCoalescer.stamp()
}

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
        let selectGeneration = sidebarSelectGeneration(for: commands)
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
                            if let intValue = Int(value) {
                                typed[key] = intValue
                            } else if value.hasPrefix("["),
                                      let data = value.data(using: .utf8),
                                      let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                                // Array-typed v2 params (e.g. child_workspace_ids)
                                // travel as JSON strings through the string-only
                                // action pipe; inflate them here.
                                typed[key] = array
                            } else {
                                typed[key] = value
                            }
                        }
                        payload["params"] = typed
                    }
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let line = String(data: data, encoding: .utf8) else { continue }
                    _ = controller.handleSocketLine(line)
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
