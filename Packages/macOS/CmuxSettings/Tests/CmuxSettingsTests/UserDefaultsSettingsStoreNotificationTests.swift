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

    @Test func observedDirectDefaultsOverwriteWithSupersededSourceRejectsOlderPendingSource() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let externalDefaults = UserDefaults(suiteName: suiteName)!
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let recorder = UserDefaultsSettingsEventRecorder<String>()
        let firstSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 10
        )
        let delayedSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 11
        )
        let task = Task {
            let stream = await store.valueEvents(for: key)
            for await event in stream {
                await recorder.append(event)
                if await recorder.count() >= 2 {
                    break
                }
            }
        }
        defer {
            task.cancel()
        }

        await waitForEventCount(1, in: recorder)

        await store.set("#LOCAL", for: key, source: firstSource)
        externalDefaults.set("#EXTERNAL", forKey: key.userDefaultsKey)
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: externalDefaults
        )

        let externalEvent = await waitForEvent(in: recorder) { event in
            event.value == "#EXTERNAL" && event.supersededMutationSource == firstSource
        }
        #expect(externalEvent?.mutationSource == nil)
        #expect(externalEvent?.supersededMutationSource == firstSource)

        let acceptedSource = await store.set("#DELAYED", for: key, source: delayedSource)
        let storedValue = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(storedValue == "#EXTERNAL")
    }

    @Test func directDefaultsNotificationRejectsOlderPendingSourceBeforeDrain() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let externalDefaults = UserDefaults(suiteName: suiteName)!
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

        externalDefaults.set("#EXTERNAL", forKey: key.userDefaultsKey)
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: externalDefaults
        )

        let acceptedSource = await store.set("#STALE", for: key, source: staleSource)
        let storedValue = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(storedValue == "#EXTERNAL")
    }

    @Test func queuedDirectDefaultsNotificationDoesNotRejectNewerPendingSource() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let externalDefaults = UserDefaults(suiteName: suiteName)!
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let recorder = UserDefaultsSettingsEventRecorder<String>()
        let task = Task {
            let stream = await store.valueEvents(for: key)
            for await event in stream {
                await recorder.append(event)
                if await recorder.count() >= 2 {
                    break
                }
            }
        }
        defer {
            task.cancel()
        }

        await waitForEventCount(1, in: recorder)

        externalDefaults.set("#EXTERNAL", forKey: key.userDefaultsKey)
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: externalDefaults
        )
        let newerSource = UserDefaultsSettingsMutationSource()

        let externalEvent = await waitForEvent(in: recorder) { event in
            event.value == "#EXTERNAL"
        }
        #expect(externalEvent?.value == "#EXTERNAL")

        let acceptedSource = await store.set("#LOCAL", for: key, source: newerSource)
        let storedValue = await store.value(for: key)
        #expect(acceptedSource == newerSource)
        #expect(storedValue == "#LOCAL")
    }

    @Test func sameValueDirectDefaultsWriteSupersedesPendingSource() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let externalDefaults = UserDefaults(suiteName: suiteName)!
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let source = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 1
        )
        let stream = await store.valueEvents(for: key)
        var iterator = stream.makeAsyncIterator()

        let initial = await iterator.next()
        #expect(initial?.value == key.defaultValue)

        await store.set("#SAME", for: key, source: source)
        externalDefaults.set("#SAME", forKey: key.userDefaultsKey)

        let externalEvent = await iterator.next()
        #expect(externalEvent?.value == "#SAME")
        #expect(externalEvent?.mutationSource == nil)
        #expect(externalEvent?.supersededMutationSource == source)
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
