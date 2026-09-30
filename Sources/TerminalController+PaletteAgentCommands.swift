import AppKit
import CmuxCommandPalette
import Foundation

extension TerminalController {
    /// How long `palette.list` waits for a window to project its rows. The work
    /// on the other side is one synchronous pass over the contributions, so a
    /// few seconds only ever elapse when the main actor is busy or the target
    /// window is not mounted.
    static let paletteAgentCommandsTimeoutSeconds: TimeInterval = 5

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
    /// Params: `window_id` (optional window UUID). Naming no window reads the
    /// key window, the same default the other command palette requests use.
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

        // Resolve first so a window id that names nothing reports `not_found`
        // instead of spending the timeout waiting for an answer that no window
        // can give. A window that closes after this check simply never answers,
        // and the wait below reports a timeout.
        if let requestedWindowId {
            let windowExists = v2MainSync {
                AppDelegate.shared?.mainWindow(for: requestedWindowId) != nil
            }
            guard windowExists else {
                return .err(
                    code: "not_found",
                    message: String(
                        localized: "socket.palette.list.windowNotFound",
                        defaultValue: "No window with that id."
                    ),
                    data: ["window_id": requestedWindowId.uuidString]
                )
            }
        }

        let requestId = UUID()
        let reply: PaletteAgentCommandsReply? = socketAwaitCallback(
            timeout: Self.paletteAgentCommandsTimeoutSeconds
        ) { completion in
            Task { @MainActor in
                let window = requestedWindowId.flatMap {
                    AppDelegate.shared?.mainWindow(for: $0)
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
            // has already given up.
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
