import CmuxSettings
import Foundation
import Observation

private final class NotificationObserverBag {
    private var observers: [NSObjectProtocol] = []

    func append(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@MainActor
@Observable
final class FileExtensionOpenersValueModel {
    private(set) var current: [String: FileExtensionOpenBehavior]

    private let store: UserDefaultsSettingsStore
    @ObservationIgnored private let observerBag = NotificationObserverBag()

    init(store: UserDefaultsSettingsStore) {
        self.store = store
        self.current = FileExtensionOpenBehaviorSettings.defaultValue
        observe(FileExtensionOpenBehaviorSettings.didChangeNotification)
        observe(UserDefaults.didChangeNotification)
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    func set(_ value: [String: FileExtensionOpenBehavior]) {
        Task { @MainActor [weak self] in
            await self?.setAndRefresh(value)
        }
    }

    func setAndRefresh(_ value: [String: FileExtensionOpenBehavior]) async {
        current = FileExtensionOpenBehaviorSettings.effectiveOpeners(from: value)
        await store.setFileExtensionOpeners(value)
        await refresh()
    }

    private func observe(_ name: Notification.Name) {
        observerBag.append(
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            }
        )
    }

    func refresh() async {
        let next = await store.fileExtensionOpeners()
        guard next != current else { return }
        current = next
    }
}
