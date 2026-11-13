import CmuxScreenKit
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// The platform forwards signed carrier metadata; Rust owns its meaning and validation.
@Suite struct MacScreenCarrierDocumentTests {
    private let key = String(repeating: "a", count: 64)

    @Test func oldDocumentsKeepTheirAbsentCarrier() throws {
        let text = MacScreenRdDocument(key: key).text
        let document = try #require(MacScreenRdDocument(text: text))
        #expect(document.peerCarrier == nil)
        #expect(TicketSignaling.fingerprint(ofSDP: text) == "cmux-rd-key \(key)")
    }

    @Test func carrierIsPartOfTheAuthenticatedFingerprint() throws {
        let document = MacScreenRdDocument(key: key, peerCarrier: "rd_wg/1")
        #expect(try #require(MacScreenRdDocument(text: document.text)) == document)
        #expect(TicketSignaling.fingerprint(ofSDP: document.text) == "cmux-rd-key \(key),cmux-rd-carrier rd_wg/1")
        let changed = document.text.replacingOccurrences(of: "rd_wg/1", with: "rd_wg/2")
        #expect(TicketSignaling.fingerprint(ofSDP: changed) != TicketSignaling.fingerprint(ofSDP: document.text))
    }

    @Test func unsignedAttributeDoesNotAdvertiseSupport() throws {
        let text = MacScreenRdDocument(key: key).text + "a=cmux-rd-carrier:rd_wg/1\r\n"
        #expect(try #require(MacScreenRdDocument(text: text)).peerCarrier == nil)
    }

    @Test(arguments: ["rd_wg/2", "", "unknown"])
    func unsupportedValuesReachRustWithoutBecomingLegacy(_ value: String) throws {
        let text = MacScreenRdDocument(key: key, peerCarrier: value).text
        let document = try #require(MacScreenRdDocument(text: text))
        #expect(document.peerCarrier != nil)
        #expect(document.peerCarrier != "rd_wg/1")
    }

    @Test func duplicateCarrierIsRejectedRatherThanLastValueWinning() throws {
        let text = MacScreenRdDocument(key: key, peerCarrier: "rd_wg/1").text
            + "a=fingerprint:cmux-rd-carrier rd_wg/1\r\n"
        let document = try #require(MacScreenRdDocument(text: text))
        #expect(document.peerCarrier == "invalid:duplicate-carrier")
    }

    @MainActor @Test func answerOmitsAbsentCarrierAndForwardsUnknownValues() throws {
        var answer = MacScreenSession.Answer(session: "session", peerKey: key, stun: [], turn: [],
                                            candidates: [], socket: "/tmp/test", relayOnly: false, peerCarrier: nil)
        let old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(answer)) as? [String: Any])
        #expect(old["peer_carrier"] == nil)
        answer.peerCarrier = "rd_wg/2"
        let unknown = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(answer)) as? [String: Any])
        #expect(unknown["peer_carrier"] as? String == "rd_wg/2")
    }
}
