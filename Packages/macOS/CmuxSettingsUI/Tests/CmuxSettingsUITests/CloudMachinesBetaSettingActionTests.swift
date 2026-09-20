import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

@MainActor
@Suite
struct CloudMachinesBetaSettingActionTests {
    @Test("Cloud availability listeners see the committed setting on enable and disable")
    func notificationFollowsTheCommittedValue() async throws {
        let suite = "cmux.cloud.beta.commit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = BetaFeaturesCatalogSection().cloudMachines
        let keyName = key.userDefaultsKey
        defaults.set(false, forKey: keyName)
        let center = NotificationCenter()
        let changes = AsyncStream<Bool>.makeStream()
        let observer = center.addObserver(
            forName: Notification.Name("rightSidebarBetaFeatureDidChange"),
            object: nil,
            queue: nil
        ) { _ in
            let committedValue = UserDefaults(suiteName: suite)?.bool(forKey: keyName) ?? false
            changes.continuation.yield(committedValue)
        }
        defer {
            center.removeObserver(observer)
            changes.continuation.finish()
        }
        // Give the store actor its own non-Sendable UserDefaults handle.
        let storeDefaults = try #require(UserDefaults(suiteName: suite))
        let store = UserDefaultsSettingsStore(defaults: storeDefaults)
        let model = DefaultsValueModel(store: store, key: key)
        let action = CloudMachinesBetaSettingAction(model: model, notificationCenter: center)

        for enabled in [true, false] {
            action.setEnabled(enabled)
            #expect(model.current == enabled, "The Settings toggle remains responsive while persisting")
            #expect(await nextChange(changes.stream) == enabled,
                    "The host must read the new value when it starts or stops the tunnel")
        }
    }

    private func nextChange(_ stream: AsyncStream<Bool>) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                for await value in stream { return value }
                return nil
            }
            group.addTask {
                // A failure deadline bounds a missing callback, not a synchronization delay.
                try? await ContinuousClock().sleep(for: .seconds(5))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
