import AppKit

/// Navigation-target delivery for the Settings window, split out of
/// `SettingsWindowPresenter` (which stays under the Swift file-length
/// budget). Owns when a pending `SettingsNavigationTarget` is posted:
/// immediately for ready live content, deferred to the host root's
/// `onAppear` otherwise.
extension SettingsWindowPresenter {
    /// Ready live content receives the navigation immediately. Until the
    /// content signals readiness (a window can exist before its navigation
    /// consumer is installed — fresh creation, hidden app), the target stays
    /// pending and ``SettingsWindowHostRoot`` delivers it from `onAppear` via
    /// `deliverPendingNavigationAfterContentAppears()`.
    func deliverNavigation(reusedExistingWindow: Bool) {
        guard let target = pendingNavigationTarget else { return }
        if reusedExistingWindow && isContentReadyForNavigation {
            pendingNavigationTarget = nil
            navigationDeliveryGeneration &+= 1
            SettingsNavigationRequest.post(target)
        }
    }

    /// Marks the content ready and delivers any pending target. The post is
    /// deferred one main-actor hop so the content's own restore navigation
    /// (posted from a descendant `onAppear`) cannot clobber it, and it is
    /// generation-guarded: a newer targeted `show()` that delivered in the
    /// meantime supersedes this queued post instead of being overridden by it.
    func deliverPendingNavigationAfterContentAppears() {
        isContentReadyForNavigation = true
        guard let target = pendingNavigationTarget else { return }
        pendingNavigationTarget = nil
        navigationDeliveryGeneration &+= 1
        let generation = navigationDeliveryGeneration
        Task { @MainActor in
            guard self.navigationDeliveryGeneration == generation else { return }
            SettingsNavigationRequest.post(target)
        }
    }

    func consumePendingNavigationTarget() -> SettingsNavigationTarget? {
        let target = pendingNavigationTarget
        pendingNavigationTarget = nil
        return target
    }
}
