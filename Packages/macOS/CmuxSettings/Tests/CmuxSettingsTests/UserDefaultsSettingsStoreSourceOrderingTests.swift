import Foundation
import Testing

@testable import CmuxSettings

@Suite("UserDefaultsSettingsStore source ordering")
struct UserDefaultsSettingsStoreSourceOrderingTests {
    @Test func rejectsOlderMutationSourceAfterSupersededDeliveryBufferEvictsIt() async {
        let suiteName = "cmux.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let key = SettingCatalog().workspaceColors.selectionColorHex
        let staleOwnerID = UUID()
        let otherOwnerID = UUID()
        let staleSource = UserDefaultsSettingsMutationSource(ownerID: staleOwnerID, sequence: 1)

        await store.set("#STALE", for: key, source: staleSource)
        for value in 1...65 {
            let source = UserDefaultsSettingsMutationSource(ownerID: otherOwnerID, sequence: UInt64(value))
            await store.set("#OTHER", for: key, source: source)
        }

        await store.set("#STALE-LATE", for: key, source: staleSource)

        let value = await store.value(for: key)
        #expect(value == "#OTHER")
    }
}
