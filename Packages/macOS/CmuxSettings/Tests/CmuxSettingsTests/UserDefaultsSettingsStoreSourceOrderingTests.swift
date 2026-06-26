import Foundation
import Testing

@testable import CmuxSettings

@Suite("UserDefaultsSettingsStore source ordering")
struct UserDefaultsSettingsStoreSourceOrderingTests {
    @Test func generatedMutationSourceOrdersAreStrictlyIncreasing() {
        let first = UserDefaultsSettingsMutationSource(ownerID: UUID(), sequence: 1)
        let second = UserDefaultsSettingsMutationSource(ownerID: UUID(), sequence: 1)

        #expect(second.logicalOrder > first.logicalOrder)
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

        await store.set("#STALE-LATE", for: key, source: staleSource)

        let value = await store.value(for: key)
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
        await store.set("#STALE-LATE", for: key, source: staleSource)

        let value = await store.value(for: key)
        #expect(value == key.defaultValue)
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
        await store.set("#STALE-LATE", for: key, source: staleSource)

        let value = await store.value(for: key)
        #expect(value == "#SOURCELESS")
    }
}
