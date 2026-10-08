import CryptoKit
import Foundation
import Testing
@testable import CmuxNextUpdater

/// R114 changelog: notes are trusted only with a valid content signature,
/// and a notes file carries an optional What's New digest.
@Suite struct ReleaseNotesTests {
    private let json = Data("""
    {"version":1,"build":"3720357958801","shortVersion":"1.0.0-nightly.3720357958801","date":"2026-10-04",
     "highlights":[{"id":"card","title":"Updates you barely notice","body":"Restart when **you** want.","media":[],
                    "action":{"id":"palette.checkForUpdates","title":"Try it"}}],
     "changes":["updates: R114 install gate"]}
    """.utf8)

    @Test func aValidSignatureVerifiesAndTamperingFails() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let signature = try key.signature(for: json).base64EncodedString()
        #expect(ContentSignature.verify(json, signature: signature, publicKey: publicKey))
        var tampered = json
        tampered[tampered.startIndex] = UInt8(ascii: " ")
        #expect(!ContentSignature.verify(tampered, signature: signature, publicKey: publicKey))
        #expect(!ContentSignature.verify(json, signature: "not base64", publicKey: publicKey))
        #expect(!ContentSignature.verify(json, signature: signature))  // the real key did not sign it
    }

    @Test func notesDecode() throws {
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: json)
        #expect(notes.highlights.first?.action?.id == "palette.checkForUpdates")
        #expect(notes.changes == ["updates: R114 install gate"])
    }
}
