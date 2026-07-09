import AppKit
import CmuxBrowser
import CmuxControlSocket
import Foundation

/// `AppDelegate`'s conformance to the quit / terminate reply seam.
///
/// `ApplicationTerminateReplyCoordinator` owns the reply state machine; these
/// witnesses perform the irreducible live-AppKit and app-target work that cannot
/// leave the app target: replying to `NSApplication`, the remote-tmux
/// kill/marked-window operations, the session-snapshot and inspector teardown,
/// the dirty-workspace probe, the `StartupBreadcrumbLog` sink, the terminating
/// flag, and presenting the localized quit-confirmation alert.
extension AppDelegate: ApplicationTerminationHost {
    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool) {
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    func windowsMarkedForKillOnClose() -> [UUID] {
        remoteTmuxController.windowsMarkedForKillOnClose()
    }

    func killMarkedSessionsBeforeTerminate() async {
        await remoteTmuxController.killMarkedSessionsBeforeTerminate()
    }

    func consumeKillSessionsOnWindowClose(windowId: UUID) {
        _ = remoteTmuxController.consumeKillSessionsOnWindowClose(windowId: windowId)
    }

    func saveSessionSnapshotBeforeTerminate() {
        _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
    }

    func flushPendingClosedItemSaves() {
        closedItemHistory.flushPendingSaves()
    }

    // `hasQuitConfirmationDirtyWorkspaces()` is defined on `AppDelegate` itself
    // (it is also read by the Cmd+Q shortcut warning path) and witnesses the
    // protocol requirement directly.

    func recordTerminateBreadcrumb(_ event: String, fields: [String: String]) {
        StartupBreadcrumbLog.append(event, fields: fields)
    }

    func setTerminatingApp(_ value: Bool) {
        isTerminatingApp = value
    }

    // MARK: Ordered teardown witnesses
    //
    // `ApplicationTerminateReplyCoordinator.performTeardown()` owns the ORDER of
    // these per-subsystem stop/detach/flush operations; each witness forwards to
    // the still-app-owned subsystem. `stopSessionAutosaveTimer()` and
    // `enableSuddenTerminationIfNeeded()` are defined on `AppDelegate` itself and
    // witness their requirements directly.

    func stopSentryMemoryContextRefresh() {
        sentryStopMemoryContextRefresh()
    }

    func detachAllRemoteTmuxClients() {
        remoteTmuxController.detachAll()
    }

    func notifyPresenceAppWillTerminate() {
        PresenceHeartbeatClient.shared.appWillTerminate()
    }

    func terminateAllCloudVMActions() {
        CloudVMActionLauncher.shared.terminateAll()
    }

    func terminateAllSSHURLLaunches() {
        sshURLLaunchService.terminateAll()
    }

    func stopMobileHostService() {
        MobileHostService.shared.stop()
    }

    func stopTerminalControl() {
        terminalControl.stop()
    }

    func cleanupOwnedTemporaryImageFiles() {
        GhosttyApp.terminalPasteboard.cleanupAllOwnedTemporaryImageFiles()
    }

    func stopVSCodeServeWebController() {
        vscodeServeWebController.stop()
    }

    func flushBrowserProfilePendingSaves() {
        BrowserProfileStore.shared.flushPendingSaves()
    }

    func cancelGhosttyCrashBreadcrumbTask() {
        ghosttyCrashBreadcrumbTask?.cancel()
        ghosttyCrashBreadcrumbTask = nil
    }

    func clearNotificationStore() {
        notificationStore?.clearAll()
    }

    func markGhosttyCleanExit() {
        GhosttyCrashBreadcrumb.markCleanExit()
    }

}
