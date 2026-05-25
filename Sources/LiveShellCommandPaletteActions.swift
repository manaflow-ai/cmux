import AppKit
import Foundation

/// Helpers that bridge command palette entries to `LiveShellControl`. Kept out of
/// ContentView so palette registration stays a one-line `LiveShellCommandPaletteActions.x()` call.
@MainActor
enum LiveShellCommandPaletteActions {
    static func presentListAlert() {
        Task { @MainActor in
            do {
                let sessions = try await LiveShellControl.list()
                presentAlert(
                    title: String(
                        localized: "liveShell.alert.list.title",
                        defaultValue: "Live Shell Sessions"
                    ),
                    informativeText: formatSessions(sessions)
                )
            } catch let error as LiveShellControl.LiveShellControlError {
                presentErrorAlert(error: error)
            } catch {
                presentAlert(
                    title: String(
                        localized: "liveShell.alert.error.title",
                        defaultValue: "Live Shell"
                    ),
                    informativeText: error.localizedDescription,
                    style: .warning
                )
            }
        }
    }

    /// Looks up the focused pane's livesh session id and kills the underlying daemon shell
    /// via `liveshctl kill <id>`. The pane is left to close naturally on next SIGHUP — kill is
    /// distinct from "close pane" which only severs the bridge and leaves the daemon shell alive.
    static func killFocusedLiveShell(sessionId: String?) {
        guard let sessionId, !sessionId.isEmpty else {
            presentAlert(
                title: String(
                    localized: "liveShell.alert.noFocusedLiveShell.title",
                    defaultValue: "No Live Shell in Focus"
                ),
                informativeText: String(
                    localized: "liveShell.alert.noFocusedLiveShell.body",
                    defaultValue: "The focused pane is not running a live shell. Switch to a pane wrapped by livesh, then run this command again."
                ),
                style: .warning
            )
            return
        }
        // Suppress the "Live Shell Is Gone" modal that would otherwise fire when the bridge
        // exits with code 66 in response to our own kill.
        LiveShellChildExitHandler.suppressNextShellLostAlert(forSessionId: sessionId)
        Task { @MainActor in
            do {
                try await LiveShellControl.kill(sessionId: sessionId)
                presentAlert(
                    title: String(
                        localized: "liveShell.alert.kill.title",
                        defaultValue: "Live Shell Killed"
                    ),
                    informativeText: killBody(sessionId: sessionId)
                )
            } catch let error as LiveShellControl.LiveShellControlError {
                presentErrorAlert(error: error)
            } catch {
                presentAlert(
                    title: String(
                        localized: "liveShell.alert.error.title",
                        defaultValue: "Live Shell"
                    ),
                    informativeText: error.localizedDescription,
                    style: .warning
                )
            }
        }
    }

    static func runGarbageCollect() {
        Task { @MainActor in
            do {
                try await LiveShellControl.gc()
                presentAlert(
                    title: String(
                        localized: "liveShell.alert.gc.title",
                        defaultValue: "Live Shell GC"
                    ),
                    informativeText: String(
                        localized: "liveShell.alert.gc.body",
                        defaultValue: "Garbage collection requested. Detached shells with exited processes will be cleaned up."
                    )
                )
            } catch let error as LiveShellControl.LiveShellControlError {
                presentErrorAlert(error: error)
            } catch {
                presentAlert(
                    title: String(
                        localized: "liveShell.alert.error.title",
                        defaultValue: "Live Shell"
                    ),
                    informativeText: error.localizedDescription,
                    style: .warning
                )
            }
        }
    }

    private static func killBody(sessionId: String) -> String {
        let template = String(
            localized: "liveShell.alert.kill.body",
            defaultValue: "Sent kill for the live shell. The daemon will tear down the shell; close the pane to dismiss the dead bridge."
        )
        let prefix = String(
            localized: "liveShell.sessionLabelPrefix",
            defaultValue: "Session:"
        )
        return "\(template)\n\n\(prefix) \(sessionId)"
    }

    private static func formatSessions(_ sessions: [LiveShellSessionInfo]) -> String {
        guard !sessions.isEmpty else {
            return String(
                localized: "liveShell.alert.list.empty",
                defaultValue: "No live shell sessions are currently registered with the daemon."
            )
        }
        let header = String(
            localized: "liveShell.alert.list.header",
            defaultValue: "Live shell sessions registered with the daemon:"
        )
        let rows = sessions.map { session -> String in
            let attached = session.attached
                ? String(localized: "liveShell.session.attached", defaultValue: "attached")
                : String(localized: "liveShell.session.detached", defaultValue: "detached")
            let name = session.name.isEmpty
                ? String(localized: "liveShell.session.unnamed", defaultValue: "(unnamed)")
                : session.name
            return "• \(session.id)  [\(session.status.rawValue.lowercased()), \(attached)]  \(name)  cwd=\(session.cwd)"
        }
        return ([header, ""] + rows).joined(separator: "\n")
    }

    private static func presentErrorAlert(error: LiveShellControl.LiveShellControlError) {
        let title: String
        let body: String
        switch error {
        case .executableNotFound:
            title = String(
                localized: "liveShell.alert.notInstalled.title",
                defaultValue: "liveshctl Not Found"
            )
            body = String(
                localized: "liveShell.alert.notInstalled.body",
                defaultValue: "Could not locate the liveshctl binary. Install livesh (~/.local/bin/livesh) or set terminal.liveshctlExecutablePath in cmux.json."
            )
        case .daemonUnavailable:
            title = String(
                localized: "liveShell.alert.daemonDown.title",
                defaultValue: "liveshd Not Running"
            )
            body = String(
                localized: "liveShell.alert.daemonDown.body",
                defaultValue: "The livesh daemon is not running. Start it by opening a new pane with the livesh shell backend or by running `livesh` in any terminal."
            )
        case .nonZeroExit(let code, let stderr):
            title = String(
                localized: "liveShell.alert.error.title",
                defaultValue: "Live Shell"
            )
            let template = String(
                localized: "liveShell.alert.nonZeroExit.body",
                defaultValue: "liveshctl exited with a non-zero status."
            )
            body = "\(template)\nexit=\(code)\n\(stderr)"
        case .decodeFailure(let underlying):
            title = String(
                localized: "liveShell.alert.error.title",
                defaultValue: "Live Shell"
            )
            let template = String(
                localized: "liveShell.alert.decodeFailure.body",
                defaultValue: "Failed to decode liveshctl output."
            )
            body = "\(template)\n\(underlying.localizedDescription)"
        }
        presentAlert(title: title, informativeText: body, style: .warning)
    }

    private static func presentAlert(
        title: String,
        informativeText: String,
        style: NSAlert.Style = .informational
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(
            localized: "liveShell.alert.ok",
            defaultValue: "OK"
        ))
        alert.runModal()
    }
}
