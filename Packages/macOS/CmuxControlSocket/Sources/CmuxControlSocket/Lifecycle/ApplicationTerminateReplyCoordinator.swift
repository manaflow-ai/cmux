public import AppKit
import CmuxSettings
import Foundation

/// Owns the application quit / terminate reply state machine, draining it out of
/// the app delegate.
///
/// This coordinator sequences `applicationShouldTerminate(_:)`: it reads the
/// quit-confirmation policy from ``QuitConfirmationStore``, drives the optional
/// confirmation alert, defers the reply for remote-tmux kill-before-quit, and
/// holds the one-shot reply latch plus the watchdog Clock task. Every live
/// effect (replying to `NSApplication`, the remote-tmux kill/marked-window
/// operations, session-snapshot and inspector teardown, breadcrumbs, the
/// localized alert) stays in the composition root behind
/// ``ApplicationTerminationHost``; the coordinator never names an app-target
/// type.
///
/// ## Isolation
/// `@MainActor` because every terminate mutator (the reply latch, the
/// kill-before-quit deferral, the watchdog) originates on the main actor in the
/// app delegate. Co-locating this policy with its callers keeps the bridging to
/// the live delegate as plain main-actor calls — the same ruling that shaped
/// ``SocketControlServer`` and ``SocketListenerLifecycleCoordinator``.
@MainActor
public final class ApplicationTerminateReplyCoordinator {
    private let host: any ApplicationTerminationHost

    // Set to true when the user has already confirmed quit via the warning
    // dialog, so applicationShouldTerminate does not show a second alert.
    private var isQuitWarningConfirmed = false
    // One-shot guard for deferred terminate replies.
    private var didReplyToTerminate = false
    // True while remote tmux kill-before-quit owns the terminate reply.
    private var isAwaitingTerminateKills = false
    private var terminateKillWatchdogTask: Task<Void, Never>?

    /// Creates the terminate-reply coordinator.
    ///
    /// - Parameter host: The composition-root seam vending the live reply,
    ///   remote-tmux, teardown, breadcrumb, and confirmation-alert operations.
    public init(host: any ApplicationTerminationHost) {
        self.host = host
    }

    /// Marks quit as confirmed so a subsequent ``applicationShouldTerminate(isDevBuild:buildFlavorRawValue:)``
    /// does not show a second alert when `NSApp.terminate` re-enters the delegate.
    ///
    /// Called from the app's Cmd+Q shortcut warning path after the user confirms.
    public func markQuitWarningConfirmed() {
        isQuitWarningConfirmed = true
    }

    /// Runs the ordered `applicationWillTerminate(_:)` teardown sequence.
    ///
    /// This coordinator owns the ORDER; every step forwards to the still-app-owned
    /// subsystem through ``ApplicationTerminationHost``. The begin/complete
    /// breadcrumbs bracket the per-subsystem stop/detach/flush operations exactly
    /// as the delegate's legacy body did.
    public func performTeardown() {
        host.recordTerminateBreadcrumb("appDelegate.willTerminate.begin", fields: [:])
        host.stopSentryMemoryContextRefresh()
        host.setTerminatingApp(true)
        // Plain quit detaches local ssh clients; explicit close already killed marked sessions.
        host.detachAllRemoteTmuxClients()
        // Best-effort presence goodbye; unclean exits are covered by the
        // service's missed-heartbeat timeout.
        host.notifyPresenceAppWillTerminate()
        host.closeAllWebInspectorsBeforeAppTeardown()
        host.saveSessionSnapshotBeforeTerminate()
        host.flushPendingClosedItemSaves()
        host.stopSessionAutosaveTimer()
        host.terminateAllCloudVMActions()
        host.terminateAllSSHURLLaunches()
        host.stopMobileHostService()
        host.stopTerminalControl()
        host.cleanupOwnedTemporaryImageFiles()
        host.stopVSCodeServeWebController()
        host.flushBrowserProfilePendingSaves()
        host.cancelGhosttyCrashBreadcrumbTask()
        host.clearNotificationStore()
        host.markGhosttyCleanExit()
        host.recordTerminateBreadcrumb("appDelegate.willTerminate.complete", fields: [:])
        host.enableSuddenTerminationIfNeeded()
    }

    /// Persists the full session snapshot before an updater-driven relaunch.
    ///
    /// Mirrors the subset of ``performTeardown()`` that an in-place relaunch
    /// needs: mark terminating, snapshot the session (with scrollback), and flush
    /// pending closed-item history.
    public func persistForRelaunch() {
        host.setTerminatingApp(true)
        host.saveSessionSnapshotBeforeTerminate()
        host.flushPendingClosedItemSaves()
    }

    /// Drives the `applicationShouldTerminate(_:)` decision.
    ///
    /// - Parameters:
    ///   - isDevBuild: Whether this is a dev-flavor build (dev builds skip the
    ///     quit warning). The app resolves its build flavor.
    ///   - buildFlavorRawValue: The build flavor's raw value, for the begin
    ///     breadcrumb.
    /// - Returns: The `NSApplication.TerminateReply` the delegate must return.
    public func applicationShouldTerminate(
        isDevBuild: Bool,
        buildFlavorRawValue: String
    ) -> NSApplication.TerminateReply {
        // A re-entrant terminate must wait for the in-flight kill-before-quit reply.
        if isAwaitingTerminateKills { return .terminateLater }
        let quitConfirmationStore = QuitConfirmationStore(defaults: .standard)
        let hasDirtyWorkspaces = host.hasQuitConfirmationDirtyWorkspaces()
        let confirmQuitMode = quitConfirmationStore.confirmQuitMode

        host.recordTerminateBreadcrumb(
            "appDelegate.shouldTerminate.begin",
            fields: [
                "buildFlavor": buildFlavorRawValue,
                "confirmQuitMode": confirmQuitMode.rawValue,
                "hasDirtyWorkspaces": hasDirtyWorkspaces ? "1" : "0",
                "quitWarningConfirmed": isQuitWarningConfirmed ? "1" : "0",
                "quitWarningEnabled": quitConfirmationStore.isEnabled ? "1" : "0"
            ]
        )
        host.setTerminatingApp(true)
        host.saveSessionSnapshotBeforeTerminate()
        host.flushPendingClosedItemSaves()

        // If the user already confirmed via the Cmd+Q shortcut warning dialog,
        // or policy skips the warning, avoid a second alert.
        if !quitConfirmationStore.shouldShowConfirmation(
            isQuitWarningConfirmed: isQuitWarningConfirmed,
            hasDirtyWorkspaces: hasDirtyWorkspaces,
            isDevBuild: isDevBuild
        ) {
            host.closeAllWebInspectorsBeforeAppTeardown()
            let reason: String
            if isQuitWarningConfirmed {
                reason = "confirmed"
            } else if isDevBuild {
                reason = "devBuild"
            } else {
                reason = "policy"
            }
            // Explicit last-tab closes kill marked remote sessions before quit.
            // Plain app/window quits have no marker and only detach.
            if deferTerminateForMarkedRemoteTmuxKills(reason: reason) {
                return .terminateLater
            }
            host.recordTerminateBreadcrumb("appDelegate.shouldTerminate.terminateNow", fields: ["reason": reason])
            return .terminateNow
        }

        // Show the same confirmation dialog used by the Cmd+Q shortcut path,
        // then reply asynchronously so we can return .terminateLater now.
        host.presentQuitConfirmation { [weak self] shouldQuit in
            guard let self else { return }
            if shouldQuit {
                self.isQuitWarningConfirmed = true
                self.host.closeAllWebInspectorsBeforeAppTeardown()
                self.host.recordTerminateBreadcrumb("appDelegate.shouldTerminate.reply", fields: ["shouldQuit": "1"])
                if self.deferTerminateForMarkedRemoteTmuxKills(reason: "confirmedDialog") {
                    return
                }
            } else {
                // Reset so that the next quit attempt can show the dialog again.
                self.host.setTerminatingApp(false)
                self.clearMarkedRemoteTmuxKills()
                self.host.recordTerminateBreadcrumb("appDelegate.shouldTerminate.reply", fields: ["shouldQuit": "0"])
            }
            self.replyToTerminateOnce(shouldQuit)
        }
        host.recordTerminateBreadcrumb("appDelegate.shouldTerminate.later", fields: [:])
        return .terminateLater
    }

    /// Sole caller of the host's `NSApp.reply(toApplicationShouldTerminate:)`.
    private func replyToTerminateOnce(_ shouldTerminate: Bool) {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        host.replyToApplicationShouldTerminate(shouldTerminate)
        terminateKillWatchdogTask?.cancel()
        terminateKillWatchdogTask = nil
        // A cancelled quit ends this terminate request; the next quit must reply again.
        if !shouldTerminate {
            didReplyToTerminate = false
            isAwaitingTerminateKills = false
        }
    }

    private func deferTerminateForMarkedRemoteTmuxKills(reason: String) -> Bool {
        let markedForKill = host.windowsMarkedForKillOnClose()
        guard !markedForKill.isEmpty else { return false }
        if !isAwaitingTerminateKills {
            isAwaitingTerminateKills = true
            host.recordTerminateBreadcrumb("appDelegate.shouldTerminate.killLater", fields: ["windows": String(markedForKill.count), "reason": reason])
            Task { @MainActor in
                await self.host.killMarkedSessionsBeforeTerminate()
                self.replyToTerminateOnce(true)
            }
            // Watchdog: release quit if the deferred Task is starved inside a nested run loop.
            terminateKillWatchdogTask?.cancel()
            terminateKillWatchdogTask = Task { @MainActor [weak self] in
                try? await ContinuousClock().sleep(for: .milliseconds(3_500))
                guard !Task.isCancelled else { return }
                self?.replyToTerminateOnce(true)
            }
        }
        return true
    }

    private func clearMarkedRemoteTmuxKills() {
        for windowId in host.windowsMarkedForKillOnClose() {
            host.consumeKillSessionsOnWindowClose(windowId: windowId)
        }
    }
}
