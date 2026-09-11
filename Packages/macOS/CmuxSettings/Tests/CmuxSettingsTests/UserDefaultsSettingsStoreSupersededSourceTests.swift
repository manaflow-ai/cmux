import Foundation
import Testing
@testable import CmuxSettings

@Suite("UserDefaultsSettingsStore superseded sources", .serialized)
struct UserDefaultsSettingsStoreSupersededSourceTests {
    @Test func overwriteBeforeObservationReportsSupersededSource() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let recorder = UserDefaultsSettingsEventRecorder<String>()
        let firstSource = UserDefaultsSettingsMutationSource(ownerID: UUID(), sequence: 1, logicalOrder: 10)
        let delayedSource = UserDefaultsSettingsMutationSource(ownerID: UUID(), sequence: 1, logicalOrder: 11)
        let task = Task {
            let stream = await store.valueEvents(for: key)
            for await event in stream {
                await recorder.append(event)
            }
        }
        defer {
            task.cancel()
            UserDefaults(suiteName: suiteName)!.removePersistentDomain(forName: suiteName)
        }

        await waitForEventCount(1, in: recorder)
        await overwriteLocalValueBeforeObservation(store: store, suiteName: suiteName, key: key, source: firstSource)

        let externalEvent = await waitForEvent(in: recorder) { event in
            event.value == "#EXTERNAL" && event.supersededMutationSource == firstSource
        }
        #expect(externalEvent?.mutationSource == nil)
        #expect(externalEvent?.supersededMutationSource == firstSource)

        let acceptedSource = await store.set("#DELAYED", for: key, source: delayedSource)
        #expect(acceptedSource == nil)
        #expect(await store.value(for: key) == "#EXTERNAL")
    }

    private func overwriteLocalValueBeforeObservation(
        store: isolated UserDefaultsSettingsStore,
        suiteName: String,
        key: DefaultsKey<String>,
        source: UserDefaultsSettingsMutationSource
    ) {
        store.set("#LOCAL", for: key, source: source)
        let externalDefaults = UserDefaults(suiteName: suiteName)!
        externalDefaults.set("#EXTERNAL", forKey: key.userDefaultsKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: externalDefaults)
    }

    private func waitForEventCount<Value: SettingCodable>(
        _ expectedCount: Int,
        in recorder: UserDefaultsSettingsEventRecorder<Value>
    ) async {
        for _ in 0..<5_000 where await recorder.count() < expectedCount {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitForEvent<Value: SettingCodable>(
        in recorder: UserDefaultsSettingsEventRecorder<Value>,
        matching predicate: (UserDefaultsSettingsValueEvent<Value>) -> Bool
    ) async -> UserDefaultsSettingsValueEvent<Value>? {
        for _ in 0..<5_000 {
            if let event = await recorder.snapshot().first(where: predicate) { return event }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return nil
    }
}
