import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Security
import Testing

struct ChiefSecureStoreReplacementTests {
    @Test func aFailedReplacementPreservesThePreviousCredential() throws {
        let saved = Mutex<String?>("previous-password")
        let store = ChiefSecureStore(updateItem: { _, _ in errSecAuthFailed },
                                     addItem: { _ in errSecAuthFailed },
                                     deleteItem: { _ in saved.withLock { $0 = nil }; return errSecSuccess })
        #expect(throws: ChiefSecureStore.Failure.keychain(errSecAuthFailed)) {
            try store.save(site: "example.com", username: "new", password: "new-password")
        }
        #expect(saved.withLock { $0 } == "previous-password")
    }

    @Test func aMissingItemIsAddedAndAnExistingItemIsUpdated() throws {
        for missing in [false, true] {
            let calls = Mutex<[String]>([])
            let store = ChiefSecureStore(updateItem: { _, attributes in
                calls.withLock { $0.append("update") }
                #expect(attributes[kSecAttrAccount as String] as? String == "new")
                #expect(attributes[kSecValueData as String] as? Data == Data("new-password".utf8))
                return missing ? errSecItemNotFound : errSecSuccess
            }, addItem: { _ in calls.withLock { $0.append("add") }; return errSecSuccess },
            deleteItem: { _ in calls.withLock { $0.append("delete") }; return errSecSuccess })
            try store.save(site: "example.com", username: "new", password: "new-password")
            #expect(calls.withLock { $0 } == (missing ? ["update", "add"] : ["update"]))
        }
    }
}
