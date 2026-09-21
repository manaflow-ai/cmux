import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteCredentialTests {
    @Test func diagnosticsDoNotExposeSoftwareCredentials() {
        let secret = "test-secret-not-for-logs"
        let cases: [MobileRemoteCredentialMaterial] = [
            .password(secret),
            .privateKey(Data(secret.utf8), passphrase: secret)
        ]
        for value in cases {
            #expect(!String(describing: value).contains(secret))
            #expect(!String(reflecting: value).contains(secret))
            var dumpOutput = ""
            dump(value, to: &dumpOutput)
            #expect(!dumpOutput.contains(secret))
            #expect(Mirror(reflecting: value).children.isEmpty)
        }
    }
}
