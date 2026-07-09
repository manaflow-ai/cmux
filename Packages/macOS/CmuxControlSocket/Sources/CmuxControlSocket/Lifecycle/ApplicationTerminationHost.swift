public import AppKit
public import Foundation

/// The irreducible live-AppKit and app-target operations the quit / terminate
/// reply state machine needs from the composition root.
///
/// ``ApplicationTerminateReplyCoordinator`` owns the reply policy (the one-shot
/// reply latch, the kill-before-quit deferral, the watchdog Clock task, and the
/// quit-warning-confirmed flag). The concrete work it sequences — replying to
/// `NSApplication`, the remote-tmux kill/marked-window operations, the active
/// quit-confirmation presenter ownership, the session-snapshot and inspector
/// teardown, the dirty-workspace probe, the breadcrumb sink, and presenting the
/// localized confirmation alert — stays in the app target and is reached only
/// through this seam.
///
/// Every member is `@MainActor`: each terminate mutator originates on the main
/// actor in the app delegate, mirroring the ``SocketListenerLifecycleHost``
/// ruling that co-locates the policy with its main-actor callers.
@MainActor
public protocol ApplicationTerminationHost: AnyObject {
    /// Returns the existing pending terminate reply when a confirmation or
    /// kill-before-quit operation is already active.
    ///
    /// This mirrors the legacy app delegate's `pendingTerminateReply(...)`
    /// helper while keeping the active presenter object in the app target.
    func pendingTerminateReply(isAwaitingTerminateKills: Bool) -> NSApplication.TerminateReply?

    /// Replies to the pending `applicationShouldTerminate(_:)` request. Wraps
    /// `NSApp.reply(toApplicationShouldTerminate:)`.
    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool)

    /// The window IDs whose remote tmux sessions are marked to be killed before
    /// quit (from the remote-tmux controller's window registry).
    func windowsMarkedForKillOnClose() -> [UUID]

    /// Kills the marked remote tmux sessions before terminate completes.
    func killMarkedSessionsBeforeTerminate() async

    /// Consumes (clears) the kill-on-close marker for `windowId`.
    func consumeKillSessionsOnWindowClose(windowId: UUID)

    /// Saves the full session snapshot (including process-detected indexes and
    /// scrollback) ahead of terminate.
    func saveSessionSnapshotBeforeTerminate()

    /// Flushes any pending closed-item history saves.
    func flushPendingClosedItemSaves()

    /// Closes all open Web Inspectors before app teardown. Returns the count closed (callers may ignore).
    @discardableResult
    func closeAllWebInspectorsBeforeAppTeardown() -> Int

    /// Whether any registered or recoverable workspace has unsaved/dirty state.
    func hasQuitConfirmationDirtyWorkspaces() -> Bool

    /// Records a startup/terminate breadcrumb under `event` with the given
    /// stringly fields (forwards to the app's `StartupBreadcrumbLog`).
    func recordTerminateBreadcrumb(_ event: String, fields: [String: String])

    /// Sets the app's per-tick terminating flag (the app target owns the stored
    /// property, which many non-terminate paths read).
    func setTerminatingApp(_ value: Bool)

    // MARK: Ordered teardown witnesses
    //
    // The irreducible per-subsystem stop/detach/flush operations
    // ``ApplicationTerminateReplyCoordinator/performTeardown()`` sequences during
    // `applicationWillTerminate(_:)`. The coordinator owns the ORDER; each
    // witness forwards to the still-app-owned subsystem.

    /// Stops the Sentry memory-context refresh loop.
    func stopSentryMemoryContextRefresh()

    /// Detaches all local ssh clients for remote tmux (plain quit only; explicit
    /// last-tab close has already killed marked sessions).
    func detachAllRemoteTmuxClients()

    /// Sends the best-effort presence goodbye before terminate; unclean exits
    /// are covered by the service's missed-heartbeat timeout.
    func notifyPresenceAppWillTerminate()

    /// Stops the periodic session-autosave timer.
    func stopSessionAutosaveTimer()

    /// Terminates all in-flight Cloud VM actions.
    func terminateAllCloudVMActions()

    /// Terminates all in-flight ssh:// URL launches.
    func terminateAllSSHURLLaunches()

    /// Stops the mobile host service.
    func stopMobileHostService()

    /// Stops the terminal controller.
    func stopTerminalControl()

    /// Cleans up all owned temporary pasteboard image files.
    func cleanupOwnedTemporaryImageFiles()

    /// Stops the VS Code serve-web controller.
    func stopVSCodeServeWebController()

    /// Flushes the browser profile store's pending saves.
    func flushBrowserProfilePendingSaves()

    /// Cancels the Ghostty crash-breadcrumb task.
    func cancelGhosttyCrashBreadcrumbTask()

    /// Clears the terminal notification store.
    func clearNotificationStore()

    /// Marks a clean Ghostty exit in the crash breadcrumb.
    func markGhosttyCleanExit()

    /// Enables sudden termination if the app's state allows it.
    func enableSuddenTerminationIfNeeded()

    /// Presents the localized quit-confirmation alert asynchronously and reports
    /// the modal response plus suppression-checkbox state back on the main actor.
    ///
    /// The app target owns the presentation so all `String(localized:)` alert
    /// text and active-presenter ownership stay app-side. The deferral lets
    /// ``ApplicationTerminateReplyCoordinator/applicationShouldTerminate(isDevBuild:buildFlavorRawValue:)``
    /// return `.terminateLater` before the modal runs.
    ///
    /// - Parameters:
    ///   - ownsTerminateRequest: Whether the confirmation owns the current
    ///     `applicationShouldTerminate(_:)` reply.
    ///   - completion: Receives the alert response and suppression-button state.
    func presentQuitConfirmation(
        ownsTerminateRequest: Bool,
        completion: @escaping @MainActor (NSApplication.ModalResponse, NSControl.StateValue) -> Void
    )
}
