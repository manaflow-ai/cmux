import CmuxNextDesign

/// The critical banner a window's host pressure indicator shows (an untilClosed toast). It ends
/// itself when released, on the main actor, so a banner never outlives its indicator, even one
/// deinitialized off the main thread (as `HostPressureSubscription` does for the service).
nonisolated final class HostPressureBanner: Sendable {
    let handle: CmuxToastHandle

    @MainActor init(_ handle: CmuxToastHandle) {
        self.handle = handle
    }

    /// Ends the toast now (a no-op once it has ended).
    @MainActor func end() {
        handle.dismiss()
    }

    deinit {
        let handle = handle
        // task-owner: one hop that ends a banner released without end(); it ends after the call
        Task { @MainActor in handle.dismiss() }
    }
}
