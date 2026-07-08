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
        cmuxSidebarWorkerQueue.async {
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
                            if let intValue = Int(value) { typed[key] = intValue } else { typed[key] = value }
                        }
                        payload["params"] = typed
                    }
                    guard let data = try? JSONSerialization.data(withJSONObject: payload),
                          let line = String(data: data, encoding: .utf8) else { continue }
                    _ = controller.handleSocketLine(line)
                case let .openURL(urlString):
                    // Route through cmuxOpenURLExternally so the user's
                    // browser.preferredExternalBrowser setting is respected.
                    // NSWorkspace.open is main-only; run it synchronously to
                    // keep the command's position in the sequence.
                    if let url = URL(string: urlString) {
                        DispatchQueue.main.sync { cmuxOpenURLExternally(url) }
                    }
                case .log:
                    break
                }
            }
        }
    }
}
