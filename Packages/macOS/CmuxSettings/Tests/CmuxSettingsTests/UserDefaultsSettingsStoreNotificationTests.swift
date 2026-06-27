import Foundation
import Testing
@testable import CmuxSettings

@Suite("UserDefaultsSettingsStore notification ordering")
struct UserDefaultsSettingsStoreNotificationTests {
    @Test func observedDirectDefaultsWriteRejectsOlderPendingSource() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let staleSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 1
        )
        let stream = await store.valueEvents(for: key)
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        #expect(initial?.value == key.defaultValue)

        UserDefaults(suiteName: suiteName)!.set("#EXTERNAL", forKey: key.userDefaultsKey)
        let external = await iterator.next()
        #expect(external?.value == "#EXTERNAL")
        #expect(external?.mutationSource == nil)

        let acceptedSource = await store.set("#LOCAL", for: key, source: staleSource)

        let storedValue = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(storedValue == "#EXTERNAL")
    }

    @Test func valueEventsDrainSupersededSourceAfterUnrelatedSameValueNotification() async {
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
        )
        let key = SettingCatalog().app.appearance
        let recorder = UserDefaultsSettingsEventRecorder<AppearanceMode>()
        let task = Task {
            let stream = await store.valueEvents(for: key)
            for await event in stream {
                await recorder.append(event)
                if await recorder.count() >= 3 {
                    break
                }
            }
        }
        defer {
            task.cancel()
        }

        await waitForEventCount(1, in: recorder)

        let source = UserDefaultsSettingsMutationSource()
        await store.set(.dark, for: key, source: source)
        await store.set(.system, for: key)
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
        )

        let matchingEvent = await waitForEvent(in: recorder) { event in
            event.value == .system && event.supersededMutationSource == source
        }

        #expect(matchingEvent?.mutationSource == nil)
        #expect(matchingEvent?.supersededMutationSource == source)
    }

    private func waitForEventCount<Value: SettingCodable>(
        _ expectedCount: Int,
        in recorder: UserDefaultsSettingsEventRecorder<Value>
    ) async {
        var spins = 0
        while await recorder.count() < expectedCount, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }

    private func waitForEvent<Value: SettingCodable>(
        in recorder: UserDefaultsSettingsEventRecorder<Value>,
        matching predicate: (UserDefaultsSettingsValueEvent<Value>) -> Bool
    ) async -> UserDefaultsSettingsValueEvent<Value>? {
        var spins = 0
        while spins < 100_000 {
            if let event = await recorder.snapshot().first(where: predicate) {
                return event
            }
            await Task.yield()
            spins += 1
        }
        return nil
    }
}
