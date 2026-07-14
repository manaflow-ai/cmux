import AppKit

extension AppDelegate {
    func completeMainWindowRegistrationWhenBrowserExtensionsReady(
        tabManager: TabManager,
        window: NSWindow
    ) {
        // Session restore must finish before the bootstrap workspace becomes
        // interactive. Extension contexts repair restored pages as they load.
        completeMainWindowRegistration(tabManager: tabManager, window: window)
    }

    private func completeMainWindowRegistration(tabManager: TabManager, window: NSWindow) {
        let didApplyStartupSessionRestore = tabManager.allowsStartupSessionRestore &&
            attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
        if Self.shouldSaveSessionSnapshotAfterMainWindowRegistration(
            isTerminatingApp: isTerminatingApp,
            didApplyStartupSessionRestore: didApplyStartupSessionRestore,
            isApplyingSessionRestore: isApplyingSessionRestore,
            didAttemptStartupSessionRestore: didAttemptStartupSessionRestore
        ) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
        }
    }
}
