import AppKit

extension AppDelegate {
    func completeMainWindowRegistrationWhenBrowserExtensionsReady(
        tabManager: TabManager,
        window: NSWindow
    ) {
        guard tabManager.allowsStartupSessionRestore,
              !didAttemptStartupSessionRestore,
              let browserWebExtensionHost = tabManager.browserWebExtensionHost,
              !browserWebExtensionHost.isInitialReconciliationComplete,
              let context = contextForMainTerminalWindow(window) else {
            completeMainWindowRegistration(tabManager: tabManager, window: window)
            return
        }
        guard context.browserWebExtensionInitialReconciliationTask == nil else { return }

        context.browserWebExtensionInitialReconciliationTask = Task { @MainActor [
            weak self,
            weak context,
            weak window,
        ] in
            await browserWebExtensionHost.waitForInitialReconciliation()
            guard !Task.isCancelled,
                  let self,
                  let context,
                  let window,
                  context.window === window else { return }
            context.browserWebExtensionInitialReconciliationTask = nil
            self.completeMainWindowRegistration(tabManager: context.tabManager, window: window)
        }
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
