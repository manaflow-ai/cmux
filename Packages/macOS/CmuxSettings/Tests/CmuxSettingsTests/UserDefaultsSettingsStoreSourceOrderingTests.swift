import Foundation
import Testing

@testable import CmuxSettings

@Suite("UserDefaultsSettingsStore source ordering", .serialized)
struct UserDefaultsSettingsStoreSourceOrderingTests {
    @Test func generatedMutationSourceOrdersAreNonDecreasing() {
        let first = UserDefaultsSettingsMutationSource(ownerID: UUID(), sequence: 1)
        let second = UserDefaultsSettingsMutationSource(ownerID: UUID(), sequence: 1)

        #expect(second.logicalOrder >= first.logicalOrder)
    }

    @Test func mutationSourceIdentityIgnoresLogicalOrder() {
        let ownerID = UUID()
        let first = UserDefaultsSettingsMutationSource(
            ownerID: ownerID,
            sequence: 1,
            logicalOrder: 1
        )
        let second = UserDefaultsSettingsMutationSource(
            ownerID: ownerID,
            sequence: 1,
            logicalOrder: 2
        )

        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    @Test func rejectsOlderMutationSourceAfterSupersededDeliveryBufferEvictsIt() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let staleOwnerID = UUID()
        let otherOwnerID = UUID()
        let staleSource = UserDefaultsSettingsMutationSource(
            ownerID: staleOwnerID,
            sequence: 1,
            logicalOrder: 1
        )

        await store.set("#STALE", for: key, source: staleSource)
        for value in 1...65 {
            let source = UserDefaultsSettingsMutationSource(
                ownerID: otherOwnerID,
                sequence: UInt64(value),
                logicalOrder: UInt64(value + 1)
            )
            await store.set("#OTHER", for: key, source: source)
        }

        let acceptedSource = await store.set("#STALE-LATE", for: key, source: staleSource)

        let value = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(value == "#OTHER")
    }

    @Test func rejectsOlderMutationSourceAfterNewerSourceFromAnotherOwner() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let staleSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 1
        )
        let newerSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 2
        )

        await store.reset(key, source: newerSource)
        let acceptedSource = await store.set("#STALE-LATE", for: key, source: staleSource)

        let value = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(value == key.defaultValue)
    }

    @Test func acceptsEqualOrderMutationSourcesInsteadOfDroppingLaterWrite() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let firstSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 1
        )
        let secondSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 1
        )

        await store.set("#FIRST", for: key, source: firstSource)
        let acceptedSource = await store.set("#SECOND", for: key, source: secondSource)

        let value = await store.value(for: key)
        #expect(acceptedSource == secondSource)
        #expect(value == "#SECOND")
    }

    @Test func rejectsOlderSameOwnerMutationSourceWhenLogicalOrderTies() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let ownerID = UUID()
        let olderSource = UserDefaultsSettingsMutationSource(
            ownerID: ownerID,
            sequence: 1,
            logicalOrder: 1
        )
        let newerSource = UserDefaultsSettingsMutationSource(
            ownerID: ownerID,
            sequence: 2,
            logicalOrder: 1
        )

        await store.set("#NEWER", for: key, source: newerSource)
        let acceptedSource = await store.set("#OLDER", for: key, source: olderSource)

        let value = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(value == "#NEWER")
    }

    @Test func rejectsOlderSameOwnerMutationAfterEqualOrderWriteFromDifferentOwner() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()
        let firstOwnerOlderSource = UserDefaultsSettingsMutationSource(
            ownerID: firstOwnerID,
            sequence: 1,
            logicalOrder: 1
        )
        let firstOwnerNewerSource = UserDefaultsSettingsMutationSource(
            ownerID: firstOwnerID,
            sequence: 2,
            logicalOrder: 1
        )
        let secondOwnerSource = UserDefaultsSettingsMutationSource(
            ownerID: secondOwnerID,
            sequence: 1,
            logicalOrder: 1
        )

        await store.set("#FIRST-NEWER", for: key, source: firstOwnerNewerSource)
        await store.set("#SECOND", for: key, source: secondOwnerSource)
        let acceptedSource = await store.set("#FIRST-OLDER", for: key, source: firstOwnerOlderSource)

        let value = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(value == "#SECOND")
    }

    @Test func rejectsOlderMutationSourceAfterSourceLessWrite() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let staleSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 1
        )

        await store.set("#SOURCELESS", for: key)
        let acceptedSource = await store.set("#STALE-LATE", for: key, source: staleSource)

        let value = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(value == "#SOURCELESS")
    }

    @Test func rejectsOlderMutationSourceAfterResetAll() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let staleSource = UserDefaultsSettingsMutationSource(
            ownerID: UUID(),
            sequence: 1,
            logicalOrder: 1
        )

        await store.set("#BEFORE", for: key)
        await store.resetAll([AnySettingKey(key)])
        let acceptedSource = await store.set("#STALE-LATE", for: key, source: staleSource)

        let value = await store.value(for: key)
        #expect(acceptedSource == nil)
        #expect(value == key.defaultValue)
    }

    @Test func unrelatedNotificationAfterResetAllDoesNotRejectNewerSource() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let stream = await store.valueEvents(for: key)
        var iterator = stream.makeAsyncIterator()

        _ = await iterator.next()
        await store.set("#BEFORE", for: key)
        await store.resetAll([AnySettingKey(key)])
        for _ in 0..<1_000 {
            await Task.yield()
        }
        let source = UserDefaultsSettingsMutationSource()
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: UserDefaults(suiteName: "cmux.tests.\(UUID().uuidString)")!
        )

        let acceptedSource = await store.set("#AFTER", for: key, source: source)

        let value = await store.value(for: key)
        #expect(acceptedSource == source)
        #expect(value == "#AFTER")
    }
}
