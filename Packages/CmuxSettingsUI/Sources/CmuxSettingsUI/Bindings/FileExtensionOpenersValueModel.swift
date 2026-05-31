import CmuxSettings
import Foundation
import Observation

@MainActor
@Observable
final class FileExtensionOpenersValueModel {
    private(set) var current: [String: FileExtensionOpenBehavior]

    private let store: UserDefaultsSettingsStore

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
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: name) {
                guard let self else { return }
                await refresh()
            }
        }
    }

    func refresh() async {
        let next = await store.fileExtensionOpeners()
        guard next != current else { return }
        current = next
    }
}
