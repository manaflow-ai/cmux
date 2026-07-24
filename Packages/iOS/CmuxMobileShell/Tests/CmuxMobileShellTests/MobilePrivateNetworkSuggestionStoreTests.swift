import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

@Suite @MainActor
struct MobilePrivateNetworkSuggestionStoreTests {
    @Test func recordsSuggestionsByCanonicalDeviceIDInMemory() throws {
        let store = MobilePrivateNetworkSuggestionStore()
        let address = try #require(CmxPrivateNetworkAddress.classify(
            interfaceName: "utun4",
            address: "10.8.0.1"
        ))
        let uppercaseID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"

        store.record([address], forMacDeviceID: uppercaseID)

        #expect(store.suggestions(
            forMacDeviceID: uppercaseID.lowercased()
        ) == [address])
        #expect(store.suggestions(forMacDeviceID: "another-mac").isEmpty)
    }

    @Test func replacementAndAccountClearNeverPersistOldSuggestions() throws {
        let store = MobilePrivateNetworkSuggestionStore()
        let address = try #require(CmxPrivateNetworkAddress.classify(
            interfaceName: "en0",
            address: "192.168.1.4"
        ))
        store.record([address], forMacDeviceID: "mac-one")
        store.record([], forMacDeviceID: "mac-one")
        #expect(store.suggestions(forMacDeviceID: "mac-one").isEmpty)

        store.record([address], forMacDeviceID: "mac-one")
        store.removeAll()
        #expect(store.suggestions(forMacDeviceID: "mac-one").isEmpty)
    }
}
