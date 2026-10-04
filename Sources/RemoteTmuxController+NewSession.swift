import AppKit
import CmuxSettings
import Foundation

/// The steps of a routed New Workspace that reach outside the controller: whether routing
/// is turned on, attaching to the session that was just created, and telling the user that
/// a step failed.
struct RemoteTmuxNewSessionEnvironment {
    /// Whether New Workspace on a mirrored workspace creates a session on its host.
    var routesToMirrorHost: @MainActor () -> Bool
    /// Mirrors the new session (controller, host, session name, requesting manager, select).
    /// `false` means an attach for the same host and name got there first.
    var attach: @MainActor (RemoteTmuxController, RemoteTmuxHost, String, TabManager, Bool) throws -> Bool
    /// Reports a failed step (host, which step, requesting manager). Local creation stays
    /// suppressed either way, so the failure has to be visible.
    var reportFailure: @MainActor (RemoteTmuxHost, RemoteTmuxController.NewSessionFailure, TabManager) -> Void

    /// Reads the setting, attaches through the controller and presents an alert.
    static var live: RemoteTmuxNewSessionEnvironment {
        RemoteTmuxNewSessionEnvironment(
            routesToMirrorHost: { RemoteTmuxController.routesNewWorkspaceToMirrorHost },
            attach: { controller, host, name, manager, select in
                try controller.mirrorSession(host: host, sessionName: name, into: manager, select: select)
            },
            reportFailure: { host, failure, manager in
                RemoteTmuxController.presentNewSessionFailureAlert(host: host, failure: failure, manager: manager)
            }
        )
    }
}

extension RemoteTmuxController {
    /// A New Workspace request that goes to a mirror's host instead of creating a local
    /// workspace.
    struct NewSessionRequest {
        let host: RemoteTmuxHost
        /// The workspace that was selected when the request was made.
        let activeTabId: UUID
    }

    /// Where a routed New Workspace failed. Creating the session and attaching to
    /// it are separate steps on the host, and only the second leaves a session
    /// behind.
    enum NewSessionFailure: Equatable {
        /// `tmux new-session` did not create a session.
        case create(detail: String)
        /// The session was created and could not be attached. `removed` says
        /// whether cmux managed to remove it again.
        case attach(sessionName: String, removed: Bool, detail: String)
    }

    /// Synchronous read of the "New Workspace on the remote host" setting, resolved through
    /// the catalog key the settings store persists to.
    nonisolated static var routesNewWorkspaceToMirrorHost: Bool {
        let key = SettingCatalog().betaFeatures.remoteTmuxNewWorkspaceOnHost
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Creates a detached tmux session on the request's host and mirrors it into `manager`.
    func createAndMirrorSession(_ request: NewSessionRequest, in manager: TabManager) async {
        let host = request.host
        // The manager must still be a REGISTERED main-window context after each
        // ssh round trip. `windowId(for:)` would also answer for a closed window's
        // recoverable route and resurrect a dead manager, so it is deliberately
        // not used here.
        func managerIsLive() -> Bool {
            AppDelegate.shared?.mainWindowContexts.values
                .contains(where: { $0.tabManager === manager }) == true
        }
        // Create a detached session and read back its (auto-assigned) name.
        let name: String
        do {
            let result = try await transport(for: host).runTmux(
                ["new-session", "-d", "-P", "-F", "#{session_name}"]
            )
            // On a closed window, skip: the detached session is picked up on
            // the next attach.
            guard managerIsLive() else { return }
            let created = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded, !created.isEmpty else {
                newSessionEnvironment.reportFailure(host, .create(detail: result.stderr), manager)
                return
            }
            name = created
        } catch {
            #if DEBUG
            cmuxDebugLog("remote-tmux: new-session on active mirror's host failed: \(error)")
            #endif
            guard managerIsLive() else { return }
            newSessionEnvironment.reportFailure(host, .create(detail: error.localizedDescription), manager)
            return
        }
        // Then attach to it like any discovered session. The session exists on
        // the host from here on, so a failure is a different one: it is not
        // "could not create", and the session cmux just made must not be left
        // behind with nothing showing it.
        do {
            // The user may have moved on to another tab while the round trip
            // ran (mirror, but don't steal selection).
            let select = manager.selectedTab?.id == request.activeTabId
            _ = try newSessionEnvironment.attach(self, host, name, manager, select)
        } catch {
            #if DEBUG
            cmuxDebugLog("remote-tmux: attaching the new session \(name) failed: \(error)")
            #endif
            // Nobody has attached to it and nothing runs in it but its shell.
            let removed = (try? await transport(for: host)
                .runTmux(["kill-session", "-t", "=\(name)"]))?.succeeded == true
            guard managerIsLive() else { return }
            newSessionEnvironment.reportFailure(
                host,
                .attach(sessionName: name, removed: removed, detail: error.localizedDescription),
                manager
            )
        }
    }

    /// The part of a failed `tmux new-session`'s stderr that goes in the alert: its last
    /// non-empty line, without control characters, at most 200 characters. That line is
    /// tmux's or ssh's own reason ("duplicate session: x", "Permission denied"); the rest
    /// can be a login banner of any length, which an alert should not reproduce.
    static func newSessionFailureReason(_ detail: String) -> String? {
        let lines = detail.split(whereSeparator: \.isNewline).map { line in
            String(String.UnicodeScalarView(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                .trimmingCharacters(in: .whitespaces)
        }
        guard let reason = lines.last(where: { !$0.isEmpty }) else { return nil }
        return reason.count > 200 ? String(reason.prefix(200)) + "…" : reason
    }

    /// The alert's title and message for a failed routed New Workspace. The
    /// message ends with the host's own reason when there is one.
    static func newSessionFailureAlertText(
        host: RemoteTmuxHost,
        failure: NewSessionFailure
    ) -> (title: String, message: String) {
        let title: String
        let message: String
        let detail: String
        switch failure {
        case .create(let createDetail):
            title = String(
                localized: "dialog.remoteTmux.newSessionFailed.title",
                defaultValue: "Couldn't Create a tmux Session on \(host.destination)"
            )
            message = String(
                localized: "dialog.remoteTmux.newSessionFailed.message",
                defaultValue: "tmux new-session failed on the remote host. No workspace was created."
            )
            detail = createDetail
        case .attach(let sessionName, let removed, let attachDetail):
            title = String(
                localized: "dialog.remoteTmux.newSessionAttachFailed.title",
                defaultValue: "Couldn't Open the New tmux Session on \(host.destination)"
            )
            message = removed
                ? String(
                    localized: "dialog.remoteTmux.newSessionAttachFailed.removed.message",
                    defaultValue: "The session was created, but cmux couldn't attach to it, so it was removed from the host."
                )
                : String(
                    localized: "dialog.remoteTmux.newSessionAttachFailed.left.message",
                    defaultValue: "The session “\(sessionName)” was created, but cmux couldn't attach to it. It is still running on the host."
                )
            detail = attachDetail
        }
        return (title, newSessionFailureReason(detail).map { "\(message)\n\n\($0)" } ?? message)
    }

    static func presentNewSessionFailureAlert(host: RemoteTmuxHost, failure: NewSessionFailure, manager: TabManager) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let text = newSessionFailureAlertText(host: host, failure: failure)
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        if let window = manager.window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
