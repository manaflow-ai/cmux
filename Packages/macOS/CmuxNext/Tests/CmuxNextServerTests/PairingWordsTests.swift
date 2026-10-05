@testable import CmuxNextServer
import Foundation
import Testing

struct PairingWordsTests {
    /// The golden vector of cmux-server-core `tests/pairing.rs`
    /// (`fingerprint_words(&PK)`), with PK as the base64url thumbprint.
    @Test func matchesTheRustGoldenVector() {
        #expect(PairingWords.list.count == 2048)
        #expect(PairingWords.words(thumbprint: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo")
            == ["capable", "various", "jewel", "dress"])
    }

    @Test func refusesThumbprintsThatAreNot32Bytes() {
        #expect(PairingWords.words(thumbprint: "AAEC") == nil)
        #expect(PairingWords.words(thumbprint: "not base64 !") == nil)
    }
}
