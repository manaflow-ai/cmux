import Foundation
import Testing

@testable import CmuxSettings

/// Guards against the settings-observation leak in #5329 / #5309: each
/// `values(for:)` consumer used to park an uncancellable `Task` inside
/// `NotificationCenter.notifications(named:)`, so tearing a consumer down (e.g.
/// a view remount) left the `Task`, `AsyncStream`, and notification sequence
/// alive until the next matching notification fired — which, for a quiet key,
/// could be never. Over a long session those trios accumulated into tens of GB.
///
/// These tests assert the teardown contract through `activeSubscriberCount`:
/// cancelling a consumer must deregister its subscriber promptly, and repeated
/// create/teardown cycles must not accumulate subscribers.
@Suite struct SettingsObserverLeakTests {
    /// Polls `condition` until it holds or the deadline passes, without relying
    /// on a fixed sleep. Returns whether the condition was met.
    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test func userDefaultsConsumerDeregistersOnCancel() async {
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!)
        let catalog = SettingCatalog()

        let consumer = Task {
            for await _ in store.values(for: catalog.app.appearance) {
                // Hold the subscription open until cancelled.
            }
        }

        #expect(await eventually { await store.activeSubscriberCount == 1 })

        consumer.cancel()

        #expect(await eventually { await store.activeSubscriberCount == 0 })
    }

    @Test func userDefaultsSubscribersDoNotAccumulateAcrossChurn() async {
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!)
        let catalog = SettingCatalog()

        // Simulate many host-view remounts: spin a consumer up and tear it down.
        for cycle in 0..<50 {
            let consumer = Task {
                for await _ in store.values(for: catalog.app.appearance) {}
            }
            #expect(
                await eventually { await store.activeSubscriberCount >= 1 },
                "cycle \(cycle): consumer never registered"
            )
            consumer.cancel()
            #expect(
                await eventually { await store.activeSubscriberCount == 0 },
                "cycle \(cycle): consumer did not deregister on cancel"
            )
        }

        #expect(await eventually { await store.activeSubscriberCount == 0 })
    }

    @Test func secretConsumerDeregistersOnCancel() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-secret-leak-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecretFileStore(baseDirectory: dir)
        let key = SecretFileKey(id: "automation.socketPassword", fileName: "socket-control-password")

        let consumer = Task {
            for await _ in store.values(for: key) {}
        }

        #expect(await eventually { await store.activeSubscriberCount == 1 })

        consumer.cancel()

        #expect(await eventually { await store.activeSubscriberCount == 0 })
    }
}
