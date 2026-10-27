import CmuxNextDesign
import CmuxNextWakeups

/// The critical banner a window's host pressure indicator shows (an untilClosed toast). It ends
/// itself when released, on the main actor, so a banner never outlives its indicator, even one
/// deinitialized off the main thread (as `HostPressureSubscription` does for the service).
nonisolated final class HostPressureBanner: Sendable {
    let handle: CmuxToastHandle
    /// Where a banner released without ``end()`` posts its end.
    private let mainWork: MainWorkScheduler

    @MainActor init(_ handle: CmuxToastHandle, mainWork: MainWorkScheduler) {
        self.handle = handle
        self.mainWork = mainWork
    }

    /// Ends the toast now (a no-op once it has ended).
    @MainActor func end() {
        handle.dismiss()
    }

    deinit {
        let handle = handle
        // One visible task (the toast leaves the screen) that ends a banner released without end(); a no-op after it.
        mainWork.postFromAnyThread(.visible, owner: "HostPressureBanner.release") { handle.dismiss() }
    }
}
