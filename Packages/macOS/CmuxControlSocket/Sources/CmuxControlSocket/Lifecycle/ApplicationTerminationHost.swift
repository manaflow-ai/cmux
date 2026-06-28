public import Foundation

/// The irreducible live-AppKit and app-target operations the quit / terminate
/// reply state machine needs from the composition root.
///
/// ``ApplicationTerminateReplyCoordinator`` owns the reply policy (the one-shot
/// reply latch, the kill-before-quit deferral, the watchdog Clock task, and the
/// quit-warning-confirmed flag). The concrete work it sequences — replying to
/// `NSApplication`, the remote-tmux kill/marked-window operations, the
/// session-snapshot and inspector teardown, the dirty-workspace probe, the
/// breadcrumb sink, and presenting the localized confirmation alert — stays in
/// the app target and is reached only through this seam.
///
/// Every member is `@MainActor`: each terminate mutator originates on the main
/// actor in the app delegate, mirroring the ``SocketListenerLifecycleHost``
/// ruling that co-locates the policy with its main-actor callers.
@MainActor
public protocol ApplicationTerminationHost: AnyObject {
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

    /// Closes all open Web Inspectors before app teardown.
    func closeAllWebInspectorsBeforeAppTeardown()

    /// Whether any registered or recoverable workspace has unsaved/dirty state.
    func hasQuitConfirmationDirtyWorkspaces() -> Bool

    /// Records a startup/terminate breadcrumb under `event` with the given
    /// stringly fields (forwards to the app's `StartupBreadcrumbLog`).
    func recordTerminateBreadcrumb(_ event: String, fields: [String: String])

    /// Sets the app's per-tick terminating flag (the app target owns the stored
    /// property, which many non-terminate paths read).
    func setTerminatingApp(_ value: Bool)

    /// Presents the localized quit-confirmation alert asynchronously and reports
    /// the user's choice (`true` = quit) back on the main actor.
    ///
    /// The app target owns the presentation so all `String(localized:)` alert
    /// text and the suppression-button persistence stay app-side. The deferral
    /// (the legacy `DispatchQueue.main.async` wrapper) lets
    /// ``ApplicationTerminateReplyCoordinator/applicationShouldTerminate(isDevBuild:buildFlavorRawValue:)``
    /// return `.terminateLater` before the modal runs.
    func presentQuitConfirmation(_ completion: @escaping @MainActor (Bool) -> Void)
}
