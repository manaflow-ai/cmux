import CmuxMobileAgentChat
import CmuxMobileTransport
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileLive

/// What the phone sends a Mac at pairing: `open` names this app's bundle id, and the `auth` reply
/// carries the signature alone. The Mac's pairing code (a QR with a one-time pre-approval) is gone:
/// a phone signed in to the Mac's account pairs, and the person allows it on the Mac.
@Suite struct LinkPairingAuthTests {
    static func macKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    }

    static func pairing() -> LinkPairing {
        let keys = PhoneKeys(userID: "u1", service: "test.auth.\(UUID())", store: MemorySecretStore(), enclave: false)
        return LinkPairing(keys: keys, phoneID: MacPinTests.phone, name: "iPhone", pins: MacPins(file: nil))
    }

    /// The `auth` reply to a Mac that proved its key: a signature and nothing else (no `pairToken`).
    @Test func theAuthReplyCarriesOnlyTheSignature() async throws {
        let channel = RemoveThisPhoneUnpairTests.AuthChannel(MacPinTests.challenge(try Self.macKey()))
        let opened = LinkPairing.Opened(channel: channel, identity: "04aa", approval: "04bb", macNonce: MacPinTests.phoneNonce)
        _ = await Self.pairing().finish(.success(opened), macID: MacPinTests.mac) {}
        let reply = try #require(try channel.sent.first.map { try JSONDecoder().decode(JSONValue.self, from: $0) })
        #expect(reply["signature"]?.stringValue != nil)
        #expect(reply["pairToken"] == nil)
        guard case .object(let fields) = reply else { Issue.record("the reply is not an object"); return }
        #expect(fields.keys.sorted() == ["signature"])
    }

    /// `open` names this app's bundle id, which a tagged dev Mac matches against its own tag.
    @Test func theOpenArgsNameThisAppsBundleID() async throws {
        let link = RemoveThisPhoneUnpairTests.RecordingLink(RemoveThisPhoneUnpairTests.AuthChannel(MacPinTests.challenge(try Self.macKey())))
        var pairing = Self.pairing()
        pairing.bundleID = "dev.cmux.mobile.my-tag"
        _ = await pairing.open(link: link, macID: MacPinTests.mac)
        #expect(link.opened.first?.1["bundleId"] == "dev.cmux.mobile.my-tag")
        let quiet = RemoveThisPhoneUnpairTests.RecordingLink(RemoveThisPhoneUnpairTests.AuthChannel(MacPinTests.challenge(try Self.macKey())))
        pairing.bundleID = nil
        _ = await pairing.open(link: quiet, macID: MacPinTests.mac)
        #expect(quiet.opened.first?.1["bundleId"] == nil)
    }
}
