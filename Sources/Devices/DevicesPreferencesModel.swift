import CmuxSettings
import Foundation
import Observation

/// Shares device preference state and actions between the sidebar and Settings.
@MainActor
@Observable
final class DevicesPreferencesModel {
    private(set) var discoveryEnabled: Bool
    private(set) var incomingAccessEnabled: Bool
    private(set) var hiddenMacIDs: Set<String>
    private let store: UserDefaultsSettingsStore
    private let keys = DevicesCatalogSection()
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    init(store: UserDefaultsSettingsStore) {
        self.store = store
        discoveryEnabled = store.initialValue(for: keys.discoveryEnabled)
        incomingAccessEnabled = store.initialValue(for: keys.incomingAccessEnabled)
        hiddenMacIDs = Set(store.initialValue(for: keys.hiddenMacIDs))
    }

    deinit {
        for task in observationTasks { task.cancel() }
    }

    func start() {
        guard observationTasks.isEmpty else { return }
        let discovery = store.values(for: keys.discoveryEnabled)
        let incoming = store.values(for: keys.incomingAccessEnabled)
        let hidden = store.values(for: keys.hiddenMacIDs)
        observationTasks = [
            Task { [weak self] in
                for await value in discovery {
                    guard !Task.isCancelled else { return }
                    self?.discoveryEnabled = value
                }
            },
            Task { [weak self] in
                for await value in incoming {
                    guard !Task.isCancelled else { return }
                    self?.incomingAccessEnabled = value
                }
            },
            Task { [weak self] in
                for await value in hidden {
                    guard !Task.isCancelled else { return }
                    self?.hiddenMacIDs = Set(value)
                }
            }
        ]
    }

    func setDiscoveryEnabled(_ enabled: Bool) async {
        await store.set(enabled, for: keys.discoveryEnabled)
    }

    func setIncomingAccessEnabled(_ enabled: Bool) async {
        await store.set(enabled, for: keys.incomingAccessEnabled)
    }

    func setHidden(_ instance: SurfaceDeviceInstanceID, hidden: Bool) async {
        await store.setMacHidden(deviceID: instance.deviceID, hidden: hidden)
    }

    func isHidden(_ machine: SurfaceMachineID) -> Bool {
        machine.deviceInstance.map { hiddenMacIDs.contains($0.deviceID) } ?? false
    }
}
