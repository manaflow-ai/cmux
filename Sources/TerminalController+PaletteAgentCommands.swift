import AppKit
import CmuxCommandPalette
import Foundation

extension TerminalController {
    /// `palette.list`: the command palette rows the target window would show.
    ///
    /// The projection is a value snapshot owned by the target window. Reading
    /// it on the main actor is synchronous and never waits for SwiftUI to mount
    /// a responder or deliver a notification.
    ///
    /// Params: `window_id`, `workspace_id`, `surface_id`, `pane_id` (all
    /// optional). The window is resolved through `v2ResolveTabManager`, the same
    /// precedence every other window-scoped method uses, so naming nothing reads
    /// the active scriptable window. That matters more here than elsewhere:
    /// `NSApp.keyWindow` is nil whenever cmux is not the frontmost app, which is
    /// most of the time for an agent, so the request names its target window
    /// rather than leaving the answer to the key-window default.
    nonisolated func v2PaletteAgentCommandsList(params: [String: Any]) -> V2CallResult {
        var requestedWindowId: UUID?
        if v2HasNonNullParam(params, "window_id") {
            // Resolved through `v2UUID`, so a handle ref from `window.list` is
            // accepted here the way every other window-scoped method accepts
            // one. A named value that resolves to nothing is malformed, empty
            // strings and wrong JSON types included: answering "no cmux window
            // is open" to a caller that did name a target sends an agent
            // looking for a window that is right there.
            guard let resolved = v2UUID(params, "window_id") else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.palette.list.invalidWindowId",
                        defaultValue: "window_id must be a window UUID or ref from `window.list`."
                    ),
                    data: nil
                )
            }
            requestedWindowId = resolved
        }

        // Resolve the target window up front so a request no window can answer
        // reports `not_found` instead of spending the timeout waiting. Only the
        // id crosses back to this thread; the window itself is looked up again
        // on the main actor below.
        let targetWindowId: UUID? = {
            let tabManager = v2ResolveTabManager(params: params)
            return v2MainSync {
                guard let tabManager,
                      let app = AppDelegate.shared,
                      let windowId = app.windowId(for: tabManager),
                      app.mainWindow(for: windowId) != nil else { return nil }
                return windowId
            }
        }()
        guard let targetWindowId else {
            guard let requestedWindowId else {
                return .err(
                    code: "not_found",
                    message: String(
                        localized: "socket.palette.list.noWindow",
                        defaultValue: "No cmux window is open."
                    ),
                    data: nil
                )
            }
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.palette.list.windowNotFound",
                    defaultValue: "No window with that id."
                ),
                data: ["window_id": requestedWindowId.uuidString]
            )
        }

        guard let reply = v2MainSync({
            guard let window = AppDelegate.shared?.mainWindow(for: targetWindowId) else {
                return nil
            }
            return PaletteAgentCommandsBroker.shared.snapshot(for: window)
        }) else {
            return .err(
                code: "unavailable",
                message: String(
                    localized: "socket.palette.list.unavailable",
                    defaultValue: "The window command palette is not ready."
                ),
                data: ["window_id": targetWindowId.uuidString]
            )
        }

        var result: [String: Any] = [
            "commands": reply.map { command -> [String: Any] in
                var payload: [String: Any] = [
                    "id": command.commandId,
                    "title": command.title,
                    "subtitle": command.subtitle,
                    "enabled": command.isEnabled,
                ]
                if let shortcutHint = command.shortcutHint {
                    payload["shortcut"] = shortcutHint
                }
                return payload
            },
        ]
        result["window_id"] = targetWindowId.uuidString
        return .ok(result)
    }
}
