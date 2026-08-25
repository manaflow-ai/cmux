import Foundation
import Observation

/// Projects the host-owned phone-forwarding configuration into Settings while
/// keeping every write on the same mutation path used by the notification page,
/// iPhone RPC, and control socket.
@MainActor
@Observable
final class MobilePhonePushSettingsModel {
    private(set) var current: MobilePhonePushSettingsSnapshot

    @ObservationIgnored private let currentSettings:
        () -> MobilePhonePushSettingsSnapshot
    @ObservationIgnored private let makeStream:
        () -> AsyncStream<MobilePhonePushSettingsSnapshot>
    @ObservationIgnored private let mutate:
        (MobilePhonePushSettingsMutation) -> MobilePhonePushSettingsSnapshot
    @ObservationIgnored private let driver =
        SettingReadDriver<MobilePhonePushSettingsSnapshot>()
    @ObservationIgnored private var hasStarted = false

    convenience init(hostActions: SettingsHostActions) {
        self.init(
            currentSettings: { hostActions.mobilePhonePushSettings() },
            makeStream: { hostActions.mobilePhonePushSettingsUpdates() },
            mutate: { hostActions.updateMobilePhonePushSettings($0) }
        )
    }

    init(
        currentSettings: @escaping () -> MobilePhonePushSettingsSnapshot,
        makeStream: @escaping () -> AsyncStream<MobilePhonePushSettingsSnapshot>,
        mutate: @escaping (
            MobilePhonePushSettingsMutation
        ) -> MobilePhonePushSettingsSnapshot
    ) {
        self.currentSettings = currentSettings
        self.makeStream = makeStream
        self.mutate = mutate
        current = currentSettings()
    }

    func startObserving() {
        guard !hasStarted else { return }
        hasStarted = true
        current = currentSettings()
        driver.activate(makeStream) { [weak self] snapshot in
            self?.current = snapshot
        }
    }

    func update(_ mutation: MobilePhonePushSettingsMutation) {
        current = mutate(mutation)
    }
}
