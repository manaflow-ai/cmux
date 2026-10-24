import CmuxNextWakeups

/// A window's place in the app's ``WindowMoments``, held by the window's subscriber (its key tracker
/// or its indicator set): releasing it takes the window out.
///
/// The subscriber drops it when its last material view or indicator leaves; when the window is
/// freed with them still in it, the subscriber dies with the window and the subscription with it,
/// so a torn-down window never keeps the app listening and never stands for a later window at the
/// same address.
// Sendable: one immutable Sendable closure.
nonisolated final class WindowMomentSubscription: Sendable {
    private let release: @MainActor @Sendable () -> Void

    /// - Parameter release: Takes the window out (runs once, when the subscription is released).
    init(release: @escaping @MainActor @Sendable () -> Void) {
        self.release = release
    }

    deinit {
        // Inline on the main thread (a subscriber is released there); queued to it otherwise.
        MainDelivery().run(release)
    }
}
