import Foundation

/// Delivers each Cloud availability transition once, including the initial state.
@MainActor
final class CloudFeatureAvailabilityObserver {
    private let notificationCenter: NotificationCenter
    private let isEnabled: @MainActor () -> Bool
    private let didChange: @MainActor (Bool) -> Void
    private var previousValue: Bool?
    private var observers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = .default,
        isEnabled: @escaping @MainActor () -> Bool,
        didChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.isEnabled = isEnabled
        self.didChange = didChange
        // Register synchronously at the legacy notification seam so no closing
        // transition can be missed before async iteration starts.
        observers = [.cmuxFeatureFlagsDidChange, RightSidebarBetaFeatureSettings.didChangeNotification].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        reconcile()
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    private func reconcile() {
        let enabled = isEnabled()
        guard previousValue != enabled else { return }
        previousValue = enabled
        didChange(enabled)
    }
}
