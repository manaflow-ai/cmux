@testable import CmuxNextCredentialVault
import Foundation
import Testing

struct CredentialVaultSecretRecordTests {
    @Test func theProtectedPayloadRoundTripsValueAndScopeTogether() throws {
        let record = CredentialVaultSecretRecord(value: "private-value", scope: [.user, .agents])
        #expect(try CredentialVaultSecretRecord(data: record.encoded()) == record)
    }

    @Test func legacyValuesNeverTakeTheirScopeFromJSON() throws {
        for value in ["private-value", #"{"version":1,"value":"other","scope":["agents"]}"#] {
            let legacy = try CredentialVaultSecretRecord(data: Data(value.utf8))
            #expect(legacy.value == value)
            #expect(legacy.scope == [.user])
        }
    }

    @Test func aMalformedProtectedPayloadFailsClosed() throws {
        let record = CredentialVaultSecretRecord(value: "private-value", scope: [.user, .agents])
        var encoded = try record.encoded()
        encoded.removeLast()
        #expect(throws: CredentialVault.Failure.self) { try CredentialVaultSecretRecord(data: encoded) }
    }
}
