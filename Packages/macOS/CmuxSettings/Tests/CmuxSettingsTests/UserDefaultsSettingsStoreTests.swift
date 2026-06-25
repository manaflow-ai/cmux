import Foundation
import Testing
@testable import CmuxSettings

@Suite("UserDefaultsSettingsStore")
struct UserDefaultsSettingsStoreTests {
    private func makeStore() -> (UserDefaultsSettingsStore, SettingCatalog) {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        return (store, SettingCatalog())
    }

    private actor EventRecorder<Value: SettingCodable> {
        private var events: [UserDefaultsSettingsValueEvent<Value>] = []

        func append(_ event: UserDefaultsSettingsValueEvent<Value>) {
            events.append(event)
        }

        func count() -> Int {
            events.count
        }

        func snapshot() -> [UserDefaultsSettingsValueEvent<Value>] {
            events
        }
    }

    private func waitForEventCount<Value: SettingCodable>(
        _ expectedCount: Int,
        in recorder: EventRecorder<Value>
    ) async {
        var spins = 0
        while await recorder.count() < expectedCount, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
    }

    @Test func readsDefaultWhenUnset() async {
        let (store, catalog) = makeStore()
        let value = await store.value(for: catalog.app.appearance)
        #expect(value == .system)
    }

    @Test func roundTripsTypedEnum() async {
        let (store, catalog) = makeStore()
        await store.set(.dark, for: catalog.app.appearance)
        let value = await store.value(for: catalog.app.appearance)
        #expect(value == .dark)
    }

    @Test func workspaceAutoNamingDefaultsOffAndRoundTrips() async {
        let (store, catalog) = makeStore()
        // Auto-naming is opt-in: a fresh store must read false.
        let unset = await store.value(for: catalog.automation.workspaceAutoNaming)
        #expect(unset == false)
        await store.set(true, for: catalog.automation.workspaceAutoNaming)
        let enabled = await store.value(for: catalog.automation.workspaceAutoNaming)
        #expect(enabled == true)
        await store.reset(catalog.automation.workspaceAutoNaming)
        let reset = await store.value(for: catalog.automation.workspaceAutoNaming)
        #expect(reset == false)
    }

    @Test func autoNamingAgentDefaultsToAutoAndRoundTrips() async {
        let (store, catalog) = makeStore()
        // Default is "auto" (each session named by its own agent).
        let unset = await store.value(for: catalog.automation.autoNamingAgent)
        #expect(unset == "auto")
        await store.set("codex", for: catalog.automation.autoNamingAgent)
        let set = await store.value(for: catalog.automation.autoNamingAgent)
        #expect(set == "codex")
        await store.reset(catalog.automation.autoNamingAgent)
        let reset = await store.value(for: catalog.automation.autoNamingAgent)
        #expect(reset == "auto")
    }

    @Test func resetReturnsToDefault() async {
        let (store, catalog) = makeStore()
        await store.set(.light, for: catalog.app.appearance)
        await store.reset(catalog.app.appearance)
        let value = await store.value(for: catalog.app.appearance)
        #expect(value == .system)
    }

    @Test func valuesStreamYieldsInitialThenChanges() async {
        let (store, catalog) = makeStore()
        await store.set(.light, for: catalog.app.appearance)

        // Drive the stream synchronously: awaiting next() before each set()
        // forces the AsyncStream build closure to run (registering the
        // UserDefaults observer) and serializes change delivery, so no write's
        // notification can be missed regardless of scheduler timing.
        var iterator = store.values(for: catalog.app.appearance).makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial == .light)

        await store.set(.dark, for: catalog.app.appearance)
        let dark = await iterator.next()
        #expect(dark == .dark)

        await store.set(.system, for: catalog.app.appearance)
        let system = await iterator.next()
        #expect(system == .system)
    }

    @Test func valueEventsCarryExplicitMutationSource() async {
        let (store, catalog) = makeStore()
        let key = catalog.app.appearance
        var iterator = store.valueEvents(for: key).makeAsyncIterator()

        let initial = await iterator.next()
        #expect(initial?.value == .system)
        #expect(initial?.mutationSource == nil)

        let source = UserDefaultsSettingsMutationSource()
        await store.set(.dark, for: key, source: source)
        let tagged = await iterator.next()
        #expect(tagged?.value == .dark)
        #expect(tagged?.mutationSource == source)

        await store.set(.light, for: key)
        let untagged = await iterator.next()
        #expect(untagged?.value == .light)
        #expect(untagged?.mutationSource == nil)
    }

    @Test func valueEventsDoNotReuseMutationSourceForExternalWrite() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().app.appearance
        var iterator = store.valueEvents(for: key).makeAsyncIterator()

        let initial = await iterator.next()
        #expect(initial?.value == .system)
        #expect(initial?.mutationSource == nil)

        let source = UserDefaultsSettingsMutationSource()
        await store.set(.dark, for: key, source: source)
        let tagged = await iterator.next()
        #expect(tagged?.value == .dark)
        #expect(tagged?.mutationSource == source)

        UserDefaults(suiteName: suiteName)!.set(
            AppearanceMode.light.encodeForUserDefaults(),
            forKey: key.userDefaultsKey
        )
        let external = await iterator.next()
        #expect(external?.value == .light)
        #expect(external?.mutationSource == nil)
    }

    @Test func valueEventsDoNotTagWritesBeforeStreamCreation() async {
        let (store, catalog) = makeStore()
        let key = catalog.app.appearance
        let source = UserDefaultsSettingsMutationSource()
        await store.set(.dark, for: key, source: source)

        var iterator = store.valueEvents(for: key).makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.value == .dark)
        #expect(initial?.mutationSource == nil)
    }

    @Test func valueEventsTagWritesAfterStreamCreationBeforeFirstRead() async {
        let (store, catalog) = makeStore()
        let key = catalog.app.appearance
        let stream = store.valueEvents(for: key)

        let source = UserDefaultsSettingsMutationSource()
        await store.set(.dark, for: key, source: source)

        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.value == .dark)
        #expect(initial?.mutationSource == source)
    }

    @Test func valueEventsDeliverMutationSourceToEveryActiveObserver() async {
        let (store, catalog) = makeStore()
        let key = catalog.app.appearance
        var firstIterator = store.valueEvents(for: key).makeAsyncIterator()
        var secondIterator = store.valueEvents(for: key).makeAsyncIterator()

        let firstInitial = await firstIterator.next()
        let secondInitial = await secondIterator.next()
        #expect(firstInitial?.value == .system)
        #expect(firstInitial?.mutationSource == nil)
        #expect(secondInitial?.value == .system)
        #expect(secondInitial?.mutationSource == nil)

        let source = UserDefaultsSettingsMutationSource()
        await store.set(.dark, for: key, source: source)

        let firstTagged = await firstIterator.next()
        let secondTagged = await secondIterator.next()
        #expect(firstTagged?.value == .dark)
        #expect(firstTagged?.mutationSource == source)
        #expect(secondTagged?.value == .dark)
        #expect(secondTagged?.mutationSource == source)
    }

    @Test func valueEventsDeliverSameValueMutationSourceToEveryActiveObserver() async {
        let (store, catalog) = makeStore()
        let key = catalog.app.appearance
        let firstRecorder = EventRecorder<AppearanceMode>()
        let secondRecorder = EventRecorder<AppearanceMode>()

        let firstTask = Task {
            for await event in store.valueEvents(for: key) {
                await firstRecorder.append(event)
                if await firstRecorder.count() >= 2 {
                    break
                }
            }
        }
        let secondTask = Task {
            for await event in store.valueEvents(for: key) {
                await secondRecorder.append(event)
                if await secondRecorder.count() >= 2 {
                    break
                }
            }
        }
        defer {
            firstTask.cancel()
            secondTask.cancel()
        }

        await waitForEventCount(1, in: firstRecorder)
        await waitForEventCount(1, in: secondRecorder)

        let source = UserDefaultsSettingsMutationSource()
        await store.set(.system, for: key, source: source)

        await waitForEventCount(2, in: firstRecorder)
        await waitForEventCount(2, in: secondRecorder)

        let firstEvents = await firstRecorder.snapshot()
        let secondEvents = await secondRecorder.snapshot()
        #expect(firstEvents.count == 2)
        #expect(firstEvents.last?.value == .system)
        #expect(firstEvents.last?.mutationSource == source)
        #expect(secondEvents.count == 2)
        #expect(secondEvents.last?.value == .system)
        #expect(secondEvents.last?.mutationSource == source)
    }

    @Test func migratesLegacyKey() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        do {
            let setup = UserDefaults(suiteName: suiteName)!
            setup.set("dark", forKey: "legacyAppearance")
        }

        let migrating = DefaultsKey<AppearanceMode>(
            id: "app.appearance",
            defaultValue: .system,
            userDefaultsKey: "appearanceMode",
            legacyUserDefaultsKeys: ["legacyAppearance"]
        )

        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            migrating: [AnySettingKey(migrating)]
        )

        let value = await store.value(for: migrating)
        #expect(value == .dark)
    }

    @Test func migratesLegacyTitleCoalescingDelayKey() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        do {
            let setup = UserDefaults(suiteName: suiteName)!
            setup.set(250, forKey: "terminal.titleUpdates.coalescingMilliseconds")
        }

        let catalog = SettingCatalog()
        let key = catalog.terminal.titleUpdateCoalescingMilliseconds
        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            migrating: [AnySettingKey(key)]
        )

        let value = await store.value(for: key)
        #expect(value == 250)

        let verify = UserDefaults(suiteName: suiteName)!
        #expect(verify.object(forKey: "terminal.titleUpdates.coalescing.delayMilliseconds") as? Int == 250)
        #expect(verify.object(forKey: "terminal.titleUpdates.coalescingMilliseconds") == nil)
    }

    @Test func skipsLegacyMigrationOnTypeMismatch() async {
        // Legacy value is a Bool, but the new key expects an enum (String).
        // Migration must NOT copy the Bool into the new key; otherwise reads
        // would silently fall back to default and the legacy data would be
        // both unreadable AND removed. Skipping leaves the legacy data in
        // place for manual recovery.
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        do {
            let setup = UserDefaults(suiteName: suiteName)!
            setup.set(true, forKey: "legacyAppearance")
        }

        let migrating = DefaultsKey<AppearanceMode>(
            id: "app.appearance",
            defaultValue: .system,
            userDefaultsKey: "appearanceMode",
            legacyUserDefaultsKeys: ["legacyAppearance"]
        )

        let store = UserDefaultsSettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!,
            migrating: [AnySettingKey(migrating)]
        )

        let value = await store.value(for: migrating)
        #expect(value == .system, "type-incompatible legacy value must not be migrated")

        // The legacy key should remain untouched so admins can recover.
        let verify = UserDefaults(suiteName: suiteName)!
        #expect(verify.object(forKey: "legacyAppearance") as? Bool == true)
        #expect(verify.object(forKey: "appearanceMode") == nil)
    }
}
