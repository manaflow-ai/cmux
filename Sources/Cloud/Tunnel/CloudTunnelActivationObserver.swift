import Foundation

/// Serializes tunnel shutdown when the shared Cloud availability policy closes.
@MainActor
final class CloudTunnelActivationObserver {
    private var observations: [NSObjectProtocol] = []
    private var downTask: Task<Void, Never>?
    private let notificationCenter: NotificationCenter
    private let isStartRefused: @Sendable () -> Bool
    private let bringDown: @Sendable () async -> Void

    init(
        notificationCenter: NotificationCenter = .default,
        isStartRefused: @escaping @Sendable () -> Bool,
        bringDown: @escaping @Sendable () async -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.isStartRefused = isStartRefused
        self.bringDown = bringDown
        // Synchronous registration bridges the existing settings notifications
        // without an unobserved interval before an async iterator starts.
        for name in [RightSidebarBetaFeatureSettings.didChangeNotification, .cmuxFeatureFlagsDidChange] {
            observations.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            })
        }
        reconcile()
    }

    deinit {
        downTask?.cancel()
        for observation in observations { notificationCenter.removeObserver(observation) }
    }

    private func reconcile() {
        guard isStartRefused() else { return }
        let previous = downTask
        downTask = Task { [isStartRefused, bringDown] in
            await previous?.value
            guard !Task.isCancelled, isStartRefused() else { return }
            await bringDown()
        }
    }
}
