import AppKit
import CmuxControlSocket
import Foundation

/// `AppDelegate`'s conformance to the application activation / resign seam.
///
/// `ApplicationActivationCoordinator` owns the activation/resign sequencing;
/// these witnesses perform the irreducible live-AppKit and app-target work that
/// cannot leave the app target: the main window visibility controller's
/// pre/post-activation order-front and restore, the did-become-active breadcrumb
/// and analytics sinks, the notification store and unread reconciler, and the
/// resign-time session snapshot. `isTerminatingApp` and
/// `clearConfiguredShortcutChordState()` are defined on `AppDelegate` itself and
/// witness their requirements directly.
extension AppDelegate: ApplicationActivationHost {
    func orderFrontMainWindowsBeforeActivationIfHidden() {
        if !hasVisibleMainTerminalWindow() {
            _ = mainWindowVisibilityController.orderFrontApplicationWindowsBeforeActivation(
                windows: mainWindowsForVisibilityController(),
                reason: .applicationWillBecomeActive
            )
        }
    }

    func restoreMainWindowVisibilityAfterActivation() {
        let activationWindows = mainWindowsForVisibilityController()
        if mainWindowVisibilityController.finishPendingApplicationActivationRestore(windows: activationWindows, reason: .applicationDidBecomeActive) == nil, !hasVisibleMainTerminalWindow() {
            _ = mainWindowVisibilityController.restoreApplicationWindowsAfterActivation(windows: activationWindows, reason: .applicationDidBecomeActive)
        }
    }

    func recordDidBecomeActiveBreadcrumb() {
        sentryBreadcrumb("app.didBecomeActive", category: "lifecycle", data: [
            "tabCount": tabManager?.tabs.count ?? 0
        ])
    }

    var isActiveAnalyticsTrackingEnabled: Bool {
        telemetrySettings.enabledForCurrentLaunch && !isRunningUnderXCTestCached
    }

    func trackAnalyticsActive(reason: String) {
        PostHogAnalytics.shared.trackActive(reason: reason)
    }

    func reconcileNotificationActivationAfterDidBecomeActive() {
        guard let notificationStore else { return }
        notificationStore.handleApplicationDidBecomeActive()
        guard let tabManager else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        notificationActivationUnreadReconciler.reconcile(activeTabId: tabId, surfaceId: surfaceId)
    }

    func saveSessionSnapshotOnResignIfNeeded() {
        if Self.sessionPersistenceDecisionPolicy.shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp: isTerminatingApp) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
        }
    }
}
