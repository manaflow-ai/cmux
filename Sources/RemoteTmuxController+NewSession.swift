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
    /// Removes a routed session even when the request task is already cancelled.
    /// The SSH process must run in an uncancelled task; otherwise the transport's
    /// cancellation handler terminates the cleanup command before it reaches tmux.
    private func removeCreatedSession(host: RemoteTmuxHost, name: String) async -> Bool {
        let cleanupTransport = transport(for: host)
        return await Task.detached(priority: .utility) {
            (try? await cleanupTransport
                .runTmux(["kill-session", "-t", "=\(name)"]))?.succeeded == true
        }.value
    }

    /// A New Workspace request that goes to a mirror's host instead of creating a local
    /// workspace.
    struct NewSessionRequest {
        let host: RemoteTmuxHost
        /// The workspace that was selected when the request was made.
        let activeTabId: UUID
        /// Identity of this request, used to prevent a cancelled request from
        /// attaching after a newer request for the same window takes over.
        let id: UUID
    }

    /// Where a routed New Workspace failed. Creating the session and attaching to
    /// it are separate steps on the host, and only the second leaves a session
    /// behind.
    enum NewSessionFailure: Equatable {
        /// `tmux new-session` did not create a session.
        case create
        /// The session was created and could not be attached. `removed` says
        /// whether cmux managed to remove it again.
        case attach(sessionName: String, removed: Bool)
    }

    /// Synchronous read of the "New Workspace on the remote host" setting, resolved through
    /// the catalog key the settings store persists to.
    nonisolated static var routesNewWorkspaceToMirrorHost: Bool {
        let key = SettingCatalog().betaFeatures.remoteTmuxNewWorkspaceOnHost
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Creates a detached tmux session on the request's host and mirrors it into `manager`.
    func createAndMirrorSession(
        _ request: NewSessionRequest,
        in manager: TabManager,
        onCreated: (@MainActor () -> Void)? = nil
    ) async {
        let host = request.host
        // The manager must still be a REGISTERED main-window context after each
        // ssh round trip. `windowId(for:)` would also answer for a closed window's
        // recoverable route and resurrect a dead manager, so it is deliberately
        // not used here.
        func managerIsLive() -> Bool {
            AppDelegate.shared?.mainWindowContexts.values
                .contains(where: { $0.tabManager === manager }) == true
        }
        func requestIsCurrent() -> Bool {
            let managerID = ObjectIdentifier(manager)
            guard let current = newSessionRequestIDs[managerID] else {
                // Direct test calls do not register through handleNewWorkspaceRequested.
                return !Task.isCancelled
            }
            return current == request.id && !Task.isCancelled
        }
        guard requestIsCurrent() else { return }
        if let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == request.activeTabId }),
           isMultiplexed(mirror) {
            guard managerIsLive(), requestIsCurrent() else { return }
            if createMultiplexedNewSession(
                host: host,
                originatingTabId: request.activeTabId,
                manager: manager,
                requestID: request.id,
                onCreated: onCreated
            ) {
                return
            }
            newSessionEnvironment.reportFailure(host, .create, manager)
            return
        }
        // Create a detached session with a unique name. Keeping the name known before
        // the SSH round trip lets cancellation clean up even when runTmux throws before
        // returning the command's stdout.
        let requestedName = "cmux-new-\(UUID().uuidString.lowercased().prefix(12))"
        let name: String
        do {
            let result = try await transport(for: host).runTmux(
                [
                    "new-session", "-d", "-s", requestedName,
                    "-x", "\(RemoteTmuxViewConnection.defaultInitialCols)",
                    "-y", "\(RemoteTmuxViewConnection.defaultInitialRows)",
                    "-P", "-F", "#{session_name}",
                ]
            )
            let created = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // A closed window no longer has a requester who can pick up this
            // detached session. Remove the session cmux just created instead of
            // leaving an unreported remote orphan behind.
            guard managerIsLive(), requestIsCurrent() else {
                // The command may have been accepted before the window closed, including when
                // ssh reported a failure or returned a truncated `-P` response. The unique name
                // makes this best-effort kill safe even when nothing was created.
                _ = await removeCreatedSession(
                    host: host,
                    name: result.succeeded && !created.isEmpty ? created : requestedName
                )
                return
            }
            if !result.succeeded, !created.isEmpty, created != requestedName {
                #if DEBUG
                cmuxDebugLog("remote-tmux: failed new-session returned unexpected output")
                #endif
                let removed = await removeCreatedSession(host: host, name: requestedName)
                if removed {
                    newSessionEnvironment.reportFailure(host, .create, manager)
                } else {
                    // The command failed, but a remote banner may have obscured the
                    // requested name after tmux created it. Report the cleanup miss
                    // without exposing that untrusted output or the session name.
                    newSessionEnvironment.reportFailure(
                        host,
                        .attach(sessionName: requestedName, removed: false),
                        manager
                    )
                }
                return
            }
            guard !created.isEmpty else {
                #if DEBUG
                cmuxDebugLog("remote-tmux: new-session returned no session: \(result.stderr)")
                #endif
                // An empty/truncated `-P` response may still follow a successful command,
                // while a nonzero command with no output has no evidence of a session.
                let removed = await removeCreatedSession(host: host, name: requestedName)
                if result.succeeded {
                    newSessionEnvironment.reportFailure(
                        host,
                        .attach(sessionName: requestedName, removed: removed),
                        manager
                    )
                } else {
                    newSessionEnvironment.reportFailure(host, .create, manager)
                }
                return
            }
            // A nonzero SSH status can still carry the explicitly requested session name
            // when the remote tmux command was accepted before the transport failed. Treat
            // that as an attach-stage failure so cleanup status is reported accurately.
            name = created
        } catch is CancellationError {
            // The remote command may have created the session before local
            // cancellation terminated ssh. The name is known up front, so a
            // best-effort kill prevents a superseded request from stranding it.
            // Run the cleanup outside this cancelled task; otherwise its SSH
            // process would be terminated before the command reached the host.
            _ = await removeCreatedSession(host: host, name: requestedName)
            return
        } catch {
            #if DEBUG
            cmuxDebugLog("remote-tmux: new-session on active mirror's host failed: \(error)")
            #endif
            guard managerIsLive(), requestIsCurrent() else { return }
            newSessionEnvironment.reportFailure(host, .create, manager)
            return
        }
        // Then attach to it like any discovered session. The session exists on
        // the host from here on, so a failure is a different one: it is not
        // "could not create", and the session cmux just made must not be left
        // behind with nothing showing it.
        do {
            guard requestIsCurrent() else {
                _ = await removeCreatedSession(host: host, name: name)
                return
            }
            // The user may have moved on to another tab while the round trip
            // ran (mirror, but don't steal selection).
            let select = manager.selectedTab?.id == request.activeTabId
            let attached = try newSessionEnvironment.attach(self, host, name, manager, select)
            guard attached else {
                // `false` also means a concurrent attach admitted this exact
                // session first. That is a successful mirror race, not an
                // orphan, so leave the existing mirror and complete the action.
                if let existingMirror = sessionMirror(host: host, sessionName: name),
                   let existingWorkspace = existingMirror.mirroredWorkspace,
                   AppDelegate.shared?.mainWindowContexts.values.contains(where: { context in
                       context.tabManager.tabs.contains(where: { $0.id == existingWorkspace.id })
                   }) == true {
                    // A concurrent attach may have won the race, but a newer
                    // request for this manager still owns the user-facing
                    // completion. Leave the live mirror in place without letting
                    // a superseded request run placement/selection callbacks.
                    guard requestIsCurrent() else { return }
                    onCreated?()
                    return
                }
                // A non-throwing miss means no mirror was admitted for the session
                // this request just created. Treat it like an attach failure so the
                // session cannot remain on the host with no cmux workspace showing it.
                let removed = await removeCreatedSession(host: host, name: name)
                guard managerIsLive(), requestIsCurrent() else { return }
                newSessionEnvironment.reportFailure(
                    host,
                    .attach(sessionName: name, removed: removed),
                    manager
                )
                return
            }
            onCreated?()
        } catch {
            #if DEBUG
            cmuxDebugLog("remote-tmux: attaching the new session \(name) failed: \(error)")
            #endif
            // Nobody has attached to it and nothing runs in it but its shell.
            let removed = await removeCreatedSession(host: host, name: name)
            guard managerIsLive(), requestIsCurrent() else { return }
            newSessionEnvironment.reportFailure(
                host,
                .attach(sessionName: name, removed: removed),
                manager
            )
        }
    }

    /// Fixed, localized alert text for a failed routed New Workspace. Remote stderr and
    /// error descriptions stay in debug logs only; they may contain untrusted host output.
    nonisolated static func newSessionFailureAlertText(
        host: RemoteTmuxHost,
        failure: NewSessionFailure
    ) -> (title: String, message: String) {
        let title: String
        let message: String
        switch failure {
        case .create:
            title = String(
                localized: "dialog.remoteTmux.newSessionFailed.title",
                defaultValue: "Couldn't Create a tmux Session on \(host.destination)"
            )
            message = String(
                localized: "dialog.remoteTmux.newSessionFailed.message",
                defaultValue: "tmux new-session failed on the remote host. No workspace was created."
            )
        case .attach(_, let removed):
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
                    defaultValue: "The session was created, but cmux couldn't attach to it. It is still running on the host."
                )
        }
        return (title, message)
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
