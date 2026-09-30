import AppKit
import CmuxCommandPalette
import Foundation

extension TerminalController {
    /// How long `palette.list` waits for a window to project its rows. The work
    /// on the other side is one synchronous pass over the contributions, so a
    /// few seconds only ever elapse when the main actor is busy or the target
    /// window is not mounted.
    nonisolated static let paletteAgentCommandsTimeoutSeconds: TimeInterval = 5

    /// `palette.list`: the command palette rows the target window would show.
    ///
    /// Runs on the socket worker. The listing is produced by the window's
    /// SwiftUI body on the main actor, so this handler registers a waiter with
    /// `PaletteAgentCommandsBroker` and blocks until that window answers.
    /// Waiting on the main thread instead would deadlock, because the body that
    /// has to answer cannot run while the main thread is parked; keeping the
    /// method in the socket-worker lane of `ControlCommandExecutionPolicy` is
    /// what makes the wait safe.
    ///
    /// Params: `window_id`, `workspace_id`, `surface_id`, `pane_id` (all
    /// optional). The window is resolved through `v2ResolveTabManager`, the same
    /// precedence every other window-scoped method uses, so naming nothing reads
    /// the active scriptable window. That matters more here than elsewhere:
    /// `NSApp.keyWindow` is nil whenever cmux is not the frontmost app, which is
    /// most of the time for an agent, so the request names its target window
    /// rather than leaving the answer to the key-window default.
    nonisolated func v2PaletteAgentCommandsList(params: [String: Any]) -> V2CallResult {
        let rawWindowId = (params["window_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var requestedWindowId: UUID?
        if let rawWindowId, !rawWindowId.isEmpty {
            guard let parsed = UUID(uuidString: rawWindowId) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.palette.list.invalidWindowId",
                        defaultValue: "window_id must be a window UUID."
                    ),
                    data: nil
                )
            }
            requestedWindowId = parsed
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

        let requestId = UUID()
        let reply: PaletteAgentCommandsReply? = socketAwaitCallback(
            timeout: Self.paletteAgentCommandsTimeoutSeconds
        ) { completion in
            Task { @MainActor in
                // A window that closes between being resolved and being asked
                // leaves nothing to answer, so no waiter is registered and the
                // wait below reports a timeout.
                guard let window = AppDelegate.shared?.mainWindow(for: targetWindowId) else {
                    return
                }
                PaletteAgentCommandsBroker.shared.request(
                    id: requestId,
                    window: window,
                    completion: completion
                )
            }
        }

        guard let reply else {
            // Drop the waiter so a late answer does not fire into a caller that
            // has already given up. Cancelling an id that was never registered,
            // which is the closed-window case above, is a no-op.
            Task { @MainActor in
                PaletteAgentCommandsBroker.shared.cancel(id: requestId)
            }
            return .err(
                code: "timeout",
                message: String(
                    localized: "socket.palette.list.timeout",
                    defaultValue: "No window answered in time."
                ),
                data: ["timeout_seconds": Self.paletteAgentCommandsTimeoutSeconds]
            )
        }

        var result: [String: Any] = [
            "commands": reply.commands.map { command -> [String: Any] in
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
        if let windowId = reply.windowId {
            result["window_id"] = windowId.uuidString
        }
        return .ok(result)
    }
}
