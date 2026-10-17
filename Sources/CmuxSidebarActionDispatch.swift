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
/// socket CLI uses). `log(...)` appends an info entry to the selected
/// workspace's existing sidebar log, which can be read with `cmux list-log` or
/// `cmux sidebar-state`. JS sidebars' gesture-gated `clipboard.write` goes
/// through the same plain-text pasteboard helper as the built-in Copy
/// Workspace ID / Link commands.
@MainActor
func makeCmuxSidebarActionDispatch() -> SidebarActionDispatch {
    let quotedLogMessage: @Sendable (String) -> String = { message in
        // The v1 sidebar command parser accepts a quoted argument and decodes
        // these escapes. Keep the message as one positional argument even
        // when a handler logs whitespace or line breaks.
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
    let controller = TerminalController.shared

    return SidebarActionDispatch(run: { action in
        // Capture the controller on the main actor, then run the whole command
        // sequence on the serial worker queue so the commands keep their authored
        // order. handleSocketLine runs worker-lane methods (browser JS, waits) on
        // this thread and hops main-actor methods back to the main actor itself,
        // so nothing here blocks SwiftUI and ordering is preserved end to end.
        let commands = action.commands
        let selectedWorkspaceID = controller.tabManager?.selectedTabId
        let selectGeneration = sidebarSelectCoalescer.generation(for: commands)
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
                case let .log(message):
                    let quotedMessage = quotedLogMessage(message)
                    let tabOption = selectedWorkspaceID.map { " --tab=\($0.uuidString)" } ?? ""
                    _ = controller.handleSocketLine(
                        "log\(tabOption) --source=custom-sidebar -- \(quotedMessage)"
                    )
                }
            }
        }
    }, writeClipboard: { text in
        WorkspaceSurfaceIdentifierClipboardText.copy(text)
    })
}
