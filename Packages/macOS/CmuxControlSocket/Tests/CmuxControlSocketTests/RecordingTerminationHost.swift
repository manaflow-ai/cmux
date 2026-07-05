import AppKit
import Foundation
@testable import CmuxControlSocket

@MainActor
final class RecordingTerminationHost: ApplicationTerminationHost {
    private(set) var events: [String] = []
    var pendingReply: NSApplication.TerminateReply?
    var hasDirtyWorkspaces = false
    var markedWindows: [UUID] = []
    var presentedCompletion: (@MainActor (NSApplication.ModalResponse, NSControl.StateValue) -> Void)?

    init(pendingReply: NSApplication.TerminateReply? = nil) {
        self.pendingReply = pendingReply
    }

    func pendingTerminateReply(isAwaitingTerminateKills: Bool) -> NSApplication.TerminateReply? {
        events.append("pending:\(isAwaitingTerminateKills)")
        return pendingReply
    }

    func replyToApplicationShouldTerminate(_ shouldTerminate: Bool) {
        events.append("reply:\(shouldTerminate)")
    }

    func windowsMarkedForKillOnClose() -> [UUID] {
        events.append("markedWindows")
        return markedWindows
    }

    func killMarkedSessionsBeforeTerminate() async {
        events.append("killMarked")
    }

    func consumeKillSessionsOnWindowClose(windowId: UUID) {
        events.append("consume:\(windowId.uuidString)")
    }

    func saveSessionSnapshotBeforeTerminate() {
        events.append("snapshot")
    }

    func flushPendingClosedItemSaves() {
        events.append("flushClosedItems")
    }

    func closeAllWebInspectorsBeforeAppTeardown() -> Int {
        events.append("closeInspectors")
        return 0
    }

    func hasQuitConfirmationDirtyWorkspaces() -> Bool {
        events.append("dirtyWorkspaces")
        return hasDirtyWorkspaces
    }

    func recordTerminateBreadcrumb(_ event: String, fields: [String: String]) {
        events.append("breadcrumb:\(event)")
    }

    func setTerminatingApp(_ value: Bool) {
        events.append("setTerminating:\(value)")
    }

    func stopSentryMemoryContextRefresh() {
        events.append("stopSentry")
    }

    func detachAllRemoteTmuxClients() {
        events.append("detachRemoteTmux")
    }

    func notifyPresenceAppWillTerminate() {
        events.append("presenceGoodbye")
    }

    func stopSessionAutosaveTimer() {
        events.append("stopAutosave")
    }

    func terminateAllCloudVMActions() {
        events.append("terminateCloudVM")
    }

    func terminateAllSSHURLLaunches() {
        events.append("terminateSSHURL")
    }

    func stopMobileHostService() {
        events.append("stopMobileHost")
    }

    func stopTerminalControl() {
        events.append("stopTerminal")
    }

    func cleanupOwnedTemporaryImageFiles() {
        events.append("cleanupPasteboardTemps")
    }

    func stopVSCodeServeWebController() {
        events.append("stopVSCode")
    }

    func flushBrowserProfilePendingSaves() {
        events.append("flushBrowserProfiles")
    }

    func cancelGhosttyCrashBreadcrumbTask() {
        events.append("cancelGhosttyCrashTask")
    }

    func clearNotificationStore() {
        events.append("clearNotifications")
    }

    func markGhosttyCleanExit() {
        events.append("markGhosttyCleanExit")
    }

    func enableSuddenTerminationIfNeeded() {
        events.append("enableSuddenTermination")
    }

    func presentQuitConfirmation(
        ownsTerminateRequest: Bool,
        completion: @escaping @MainActor (NSApplication.ModalResponse, NSControl.StateValue) -> Void
    ) {
        events.append("present:\(ownsTerminateRequest)")
        presentedCompletion = completion
    }
}
