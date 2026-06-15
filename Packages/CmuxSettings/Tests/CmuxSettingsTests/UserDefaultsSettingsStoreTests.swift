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

        let observed = Task<[AppearanceMode], Never> {
            var collected: [AppearanceMode] = []
            for await mode in store.values(for: catalog.app.appearance) {
                collected.append(mode)
                if collected.count == 3 { break }
            }
            return collected
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        await store.set(.dark, for: catalog.app.appearance)
        try? await Task.sleep(nanoseconds: 50_000_000)
        await store.set(.system, for: catalog.app.appearance)

        let collected = await observed.value
        #expect(collected == [.light, .dark, .system])
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
