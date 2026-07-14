import AppKit

/// Navigation-target delivery for the Settings window, split out of
/// `SettingsWindowPresenter` (which stays under the Swift file-length
/// budget). Owns when a pending `SettingsNavigationDestination` is posted:
/// immediately for ready live content, deferred to the host root's
/// `onAppear` otherwise.
extension SettingsWindowPresenter {
    @discardableResult
    static func show(
        navigationTarget: SettingsNavigationTarget?,
        activateApp: Bool = true
    ) -> SettingsWindowShowResult {
        show(
            navigationDestination: navigationTarget.map { SettingsNavigationDestination(target: $0) },
            activateApp: activateApp
        )
    }

    @discardableResult
    func show(
        navigationTarget: SettingsNavigationTarget,
        activateApp: Bool = true
    ) -> SettingsWindowShowResult {
        show(
            navigationDestination: SettingsNavigationDestination(target: navigationTarget),
            activateApp: activateApp
        )
    }

    /// Ready live content receives the navigation immediately. Until the
    /// content signals readiness (a window can exist before its navigation
    /// consumer is installed — fresh creation, hidden app), the destination stays
    /// pending and ``SettingsWindowHostRoot`` delivers it from `onAppear` via
    /// `deliverPendingNavigationAfterContentAppears()`.
    func deliverNavigation(reusedExistingWindow: Bool) {
        guard let destination = pendingNavigationDestination else { return }
        if reusedExistingWindow && isContentReadyForNavigation {
            pendingNavigationDestination = nil
            navigationDeliveryGeneration &+= 1
            SettingsNavigationRequest.post(
                destination.target,
                anchorID: destination.anchorID,
                highlight: destination.shouldHighlight
            )
        }
    }

    /// Marks the content ready and delivers any pending destination. The post is
    /// deferred one main-actor hop so the content's own restore navigation
    /// (posted from a descendant `onAppear`) cannot clobber it, and it is
    /// generation-guarded: a newer targeted `show()` that delivered in the
    /// meantime supersedes this queued post instead of being overridden by it.
    func deliverPendingNavigationAfterContentAppears() {
        isContentReadyForNavigation = true
        guard let destination = pendingNavigationDestination else { return }
        pendingNavigationDestination = nil
        navigationDeliveryGeneration &+= 1
        let generation = navigationDeliveryGeneration
        Task { @MainActor in
            guard self.navigationDeliveryGeneration == generation else { return }
            SettingsNavigationRequest.post(
                destination.target,
                anchorID: destination.anchorID,
                highlight: destination.shouldHighlight
            )
        }
    }

    func consumePendingNavigationTarget() -> SettingsNavigationTarget? {
        let destination = pendingNavigationDestination
        pendingNavigationDestination = nil
        return destination?.target
    }
}
