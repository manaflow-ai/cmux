import Foundation
import Testing

@testable import CmuxSettings

@Suite("DefaultsKey remote defaults", .serialized)
struct DefaultsKeyRemoteDefaultTests {
    private let key = DefaultsKey<Bool>(
        id: "tests.beta.enabled",
        defaultValue: false,
        userDefaultsKey: "tests.beta.enabled",
        remoteDefaultUserDefaultsKey: "tests.beta.remoteDefault.enabled"
    )

    @Test func resolutionPrefersUserThenRemoteThenCompileDefault() throws {
        let isolated = try makeDefaults()
        let defaults = isolated.defaults
        defer { defaults.removePersistentDomain(forName: isolated.suiteName) }

        #expect(key.resolution(in: defaults) == .init(value: false, source: .compileDefault))

        key.setRemoteDefault(true, in: defaults)
        #expect(key.resolution(in: defaults) == .init(value: true, source: .remoteDefault))

        key.set(true, in: defaults)
        #expect(key.resolution(in: defaults) == .init(value: true, source: .user))

        key.setRemoteDefault(false, in: defaults)
        #expect(key.resolution(in: defaults) == .init(value: true, source: .user))

        key.set(false, in: defaults)
        #expect(key.resolution(in: defaults) == .init(value: false, source: .user))

        key.removeValue(in: defaults)
        #expect(key.resolution(in: defaults) == .init(value: false, source: .remoteDefault))
    }

    @Test func invalidLayersFallThroughWithoutBecomingUserIntent() throws {
        let isolated = try makeDefaults()
        let defaults = isolated.defaults
        defer { defaults.removePersistentDomain(forName: isolated.suiteName) }
        defaults.set("invalid-user", forKey: key.userDefaultsKey)
        key.setRemoteDefault(true, in: defaults)

        #expect(key.hasStoredValue(in: defaults))
        #expect(key.resolution(in: defaults) == .init(value: true, source: .remoteDefault))

        defaults.set("invalid-remote", forKey: try #require(key.remoteDefaultUserDefaultsKey))
        #expect(key.resolution(in: defaults) == .init(value: false, source: .compileDefault))
    }

    @Test func sameEffectiveUserWritePersistsIntentAcrossRemoteChanges() throws {
        let isolated = try makeDefaults()
        let defaults = isolated.defaults
        defer { defaults.removePersistentDomain(forName: isolated.suiteName) }
        key.setRemoteDefault(true, in: defaults)

        key.set(true, in: defaults)
        #expect(defaults.object(forKey: key.userDefaultsKey) != nil)

        key.setRemoteDefault(false, in: defaults)
        #expect(key.value(in: defaults))
        #expect(key.resolution(in: defaults).source == .user)
    }

    @Test func cachedRemoteDefaultSurvivesKeyAndStoreReconstruction() async throws {
        let isolated = try makeDefaults()
        nonisolated(unsafe) let defaults = isolated.defaults
        defer { defaults.removePersistentDomain(forName: isolated.suiteName) }
        key.setRemoteDefault(true, in: defaults)

        let reconstructed = DefaultsKey<Bool>(
            id: key.id,
            defaultValue: false,
            userDefaultsKey: key.userDefaultsKey,
            remoteDefaultUserDefaultsKey: key.remoteDefaultUserDefaultsKey
        )
        let store = UserDefaultsSettingsStore(defaults: defaults)

        #expect(reconstructed.value(in: defaults))
        #expect(await store.value(for: reconstructed))
        #expect(defaults.object(forKey: reconstructed.userDefaultsKey) == nil)
    }

    @Test func resetRemovesOnlyUserChoiceAndInheritsRemoteDefault() async throws {
        let isolated = try makeDefaults()
        nonisolated(unsafe) let defaults = isolated.defaults
        defer { defaults.removePersistentDomain(forName: isolated.suiteName) }
        key.setRemoteDefault(true, in: defaults)
        key.set(false, in: defaults)
        let store = UserDefaultsSettingsStore(defaults: defaults)

        await store.reset(key)

        #expect(defaults.object(forKey: key.userDefaultsKey) == nil)
        #expect(key.remoteDefaultValue(in: defaults) == true)
        #expect(await store.value(for: key))
    }

    @Test func resetAllRemovesOnlyUserChoiceAndInheritsRemoteDefault() async throws {
        let isolated = try makeDefaults()
        nonisolated(unsafe) let defaults = isolated.defaults
        defer { defaults.removePersistentDomain(forName: isolated.suiteName) }
        key.setRemoteDefault(true, in: defaults)
        key.set(false, in: defaults)
        let store = UserDefaultsSettingsStore(defaults: defaults)

        await store.resetAll([AnySettingKey(key)])

        #expect(defaults.object(forKey: key.userDefaultsKey) == nil)
        #expect(key.remoteDefaultValue(in: defaults) == true)
        #expect(await store.value(for: key))
    }

    @Test func liveStoreObservationSeesRemoteChangeWithoutUserWrite() async throws {
        let isolated = try makeDefaults()
        nonisolated(unsafe) let defaults = isolated.defaults
        defer { defaults.removePersistentDomain(forName: isolated.suiteName) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var iterator = store.values(for: key).makeAsyncIterator()

        #expect(await iterator.next() == false)
        key.setRemoteDefault(true, in: defaults)
        #expect(await iterator.next() == true)
        #expect(defaults.object(forKey: key.userDefaultsKey) == nil)
    }

    @Test func initialValueEventClassifiesInheritedAndPrimaryLayers() async throws {
        let inherited = try makeDefaults()
        nonisolated(unsafe) let inheritedDefaults = inherited.defaults
        defer { inheritedDefaults.removePersistentDomain(forName: inherited.suiteName) }
        key.setRemoteDefault(true, in: inheritedDefaults)
        let inheritedStore = UserDefaultsSettingsStore(defaults: inheritedDefaults)
        let inheritedStream = await inheritedStore.valueEvents(for: key)
        var inheritedIterator = inheritedStream.makeAsyncIterator()
        let inheritedEvent = await inheritedIterator.next()

        #expect(inheritedEvent?.value == true)
        #expect(inheritedEvent?.isInitialSnapshot == true)
        #expect(inheritedEvent?.isInheritedDefaultChange == true)

        let primary = try makeDefaults()
        nonisolated(unsafe) let primaryDefaults = primary.defaults
        defer { primaryDefaults.removePersistentDomain(forName: primary.suiteName) }
        key.set(true, in: primaryDefaults)
        let primaryStore = UserDefaultsSettingsStore(defaults: primaryDefaults)
        let primaryStream = await primaryStore.valueEvents(for: key)
        var primaryIterator = primaryStream.makeAsyncIterator()
        let primaryEvent = await primaryIterator.next()

        #expect(primaryEvent?.value == true)
        #expect(primaryEvent?.isInitialSnapshot == true)
        #expect(primaryEvent?.isInheritedDefaultChange == false)
    }

    @Test func unchangedRemoteRefreshReportsNoStorageChange() throws {
        let isolated = try makeDefaults()
        let defaults = isolated.defaults
        defer { defaults.removePersistentDomain(forName: isolated.suiteName) }

        #expect(key.setRemoteDefault(true, in: defaults))
        #expect(!key.setRemoteDefault(true, in: defaults))
    }

    private func makeDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "cmux.tests.beta.remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
