import AppKit
import CmuxSwiftRender
import CmuxSwiftRenderUI
import Foundation

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
/// `TerminalController.runV2CommandLine(_:)` (the same surface as the socket
/// CLI); `log` is a debug-only no-op for now.
@MainActor
func makeCmuxSidebarActionDispatch() -> SidebarActionDispatch {
    SidebarActionDispatch { action in
        for command in action.commands {
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
                _ = TerminalController.shared.runV2CommandLine(line)
            case let .openURL(urlString):
                if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
            case .log:
                break
            }
        }
    }
}
