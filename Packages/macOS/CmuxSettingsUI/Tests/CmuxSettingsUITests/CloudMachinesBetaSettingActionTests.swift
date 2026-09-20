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
        let center = NotificationCenter()
        let changes = AsyncStream<Bool>.makeStream()
        // UserDefaults is thread-safe; the notification callback only reads this isolated suite.
        nonisolated(unsafe) let committedDefaults = defaults
        let observer = center.addObserver(
            forName: Notification.Name("rightSidebarBetaFeatureDidChange"),
            object: nil,
            queue: nil
        ) { _ in
            changes.continuation.yield(committedDefaults.bool(forKey: keyName))
        }
        defer {
            center.removeObserver(observer)
            changes.continuation.finish()
        }
        let store = UserDefaultsSettingsStore(defaults: defaults)
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
