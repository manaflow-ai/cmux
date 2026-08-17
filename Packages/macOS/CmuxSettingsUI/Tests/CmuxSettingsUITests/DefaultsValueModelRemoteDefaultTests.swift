import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

@Suite("DefaultsValueModel remote defaults", .serialized)
struct DefaultsValueModelRemoteDefaultTests {
    @MainActor
    @Test func resetOptimisticallyInheritsRemoteDefault() async throws {
        let suiteName = "cmux.settings.ui.remote.\(UUID().uuidString)"
        nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = DefaultsKey<Bool>(
            id: "tests.beta.enabled",
            defaultValue: false,
            userDefaultsKey: "tests.beta.enabled",
            remoteDefaultUserDefaultsKey: "tests.beta.remoteDefault.enabled"
        )
        key.setRemoteDefault(true, in: defaults)
        key.set(false, in: defaults)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let model = DefaultsValueModel(store: store, key: key)

        #expect(model.current == false)
        model.reset()
        #expect(model.current == true)
        for _ in 0..<1_000 where defaults.object(forKey: key.userDefaultsKey) != nil {
            await Task.yield()
        }
        #expect(defaults.object(forKey: key.userDefaultsKey) == nil)
    }

    @MainActor
    @Test func pendingSameValueUserIntentSurvivesSynchronousRemoteChange() async throws {
        let suiteName = "cmux.settings.ui.remote.race.\(UUID().uuidString)"
        nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = makeKey()
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let model = DefaultsValueModel(store: store, key: key)
        model.startObserving()

        for _ in 0..<100_000 where model.revision == 0 {
            await Task.yield()
        }
        #expect(model.revision > 0)
        let revisionBeforeClick = model.revision

        model.set(false)
        let revisionAfterClick = model.revision
        #expect(revisionAfterClick == revisionBeforeClick + 1)
        #expect(model.current == false)

        // The remote cache mutation is synchronous and intentionally happens
        // before the model's fire-and-forget primary write can yield.
        key.setRemoteDefault(true, in: defaults)

        var everyObservedValueStayedFalse = model.current == false
        for _ in 0..<100_000 {
            everyObservedValueStayedFalse = everyObservedValueStayedFalse && model.current == false
            if Bool.decodeFromUserDefaults(
                defaults.object(forKey: key.userDefaultsKey)
            ) == false {
                break
            }
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
            everyObservedValueStayedFalse = everyObservedValueStayedFalse && model.current == false
        }

        #expect(everyObservedValueStayedFalse)
        #expect(Bool.decodeFromUserDefaults(
            defaults.object(forKey: key.userDefaultsKey)
        ) == false)
        #expect(model.current == false)
        #expect(model.revision == revisionAfterClick)
    }

    @MainActor
    @Test func remoteChangeBelowEstablishedUserOverridePublishesNoUIRevision() async throws {
        let suiteName = "cmux.settings.ui.remote.override.\(UUID().uuidString)"
        nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = makeKey()
        key.set(false, in: defaults)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let model = DefaultsValueModel(store: store, key: key)
        model.startObserving()

        for _ in 0..<100_000 where model.revision == 0 {
            await Task.yield()
        }
        #expect(model.revision > 0)
        let revisionBeforeRemoteChange = model.revision

        key.setRemoteDefault(true, in: defaults)
        var everyObservedValueStayedFalse = model.current == false
        for _ in 0..<1_000 {
            await Task.yield()
            everyObservedValueStayedFalse = everyObservedValueStayedFalse && model.current == false
        }

        #expect(everyObservedValueStayedFalse)
        #expect(model.current == false)
        #expect(model.revision == revisionBeforeRemoteChange)
        #expect(key.resolution(in: defaults).source == .user)
    }

    @MainActor
    @Test func resetConsumesOwnedEchoWhenRemoteInheritedValueChanges() async throws {
        let suiteName = "cmux.settings.ui.remote.reset-race.\(UUID().uuidString)"
        nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = makeKey()
        key.set(true, in: defaults)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let model = DefaultsValueModel(store: store, key: key)
        model.startObserving()

        for _ in 0..<100_000 where model.revision == 0 {
            await Task.yield()
        }
        #expect(model.current)

        model.reset()
        #expect(model.current == false)
        key.setRemoteDefault(true, in: defaults)

        for _ in 0..<100_000 where
            defaults.object(forKey: key.userDefaultsKey) != nil
                || !model.pendingStoreEchoes.isEmpty
                || model.current != true {
            await Task.yield()
        }

        #expect(defaults.object(forKey: key.userDefaultsKey) == nil)
        #expect(model.current)
        #expect(model.pendingStoreEchoes.isEmpty)
        #expect(key.resolution(in: defaults) == .init(value: true, source: .remoteDefault))
    }

    @MainActor
    @Test func inheritedInitialSnapshotCannotOverwriteClickMadeBeforeObservationStarts() async throws {
        let suiteName = "cmux.settings.ui.remote.startup-race.\(UUID().uuidString)"
        nonisolated(unsafe) let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = makeKey()
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let (stream, continuation) =
            AsyncStream<UserDefaultsSettingsValueEvent<Bool>>.makeStream(
                bufferingPolicy: .unbounded
            )
        let model = DefaultsValueModel(
            store: store,
            key: key,
            initialValue: false,
            makeStream: { _ in stream }
        )

        let source = model.set(false)
        key.setRemoteDefault(true, in: defaults)
        continuation.yield(UserDefaultsSettingsValueEvent(
            value: true,
            isInitialSnapshot: true,
            isInheritedDefaultChange: true
        ))
        continuation.yield(UserDefaultsSettingsValueEvent(
            value: false,
            mutationSource: source
        ))
        model.startObserving()

        let revisionAfterClick = model.revision
        var everyObservedValueStayedFalse = model.current == false
        for _ in 0..<1_000 {
            await Task.yield()
            everyObservedValueStayedFalse = everyObservedValueStayedFalse && model.current == false
            if model.pendingStoreEchoes.isEmpty { break }
        }

        #expect(everyObservedValueStayedFalse)
        #expect(model.current == false)
        #expect(model.revision == revisionAfterClick)
        #expect(model.pendingStoreEchoes.isEmpty)
    }

    private func makeKey() -> DefaultsKey<Bool> {
        DefaultsKey(
            id: "tests.beta.enabled",
            defaultValue: false,
            userDefaultsKey: "tests.beta.enabled",
            remoteDefaultUserDefaultsKey: "tests.beta.remoteDefault.enabled"
        )
    }
}
