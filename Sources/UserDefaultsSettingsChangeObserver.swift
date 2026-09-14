import CmuxSettings
import Foundation

/// Delivers UserDefaults change signals on the main actor without making the
/// posting thread wait for main-actor work.
final class UserDefaultsSettingsChangeObserver {
    private let task: Task<Void, Never>

    init(
        defaults: UserDefaults? = nil,
        notificationCenter: NotificationCenter = .default,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        let observedDefaultsID = defaults.map { ObjectIdentifier($0) }
        let signals = UserDefaultsSettingsStore.changeSignals(
            notificationCenter: notificationCenter,
            observedDefaultsID: observedDefaultsID
        )
        task = Task { @MainActor in
            for await _ in signals {
                if Task.isCancelled { return }
                action()
            }
        }
    }

    func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}
