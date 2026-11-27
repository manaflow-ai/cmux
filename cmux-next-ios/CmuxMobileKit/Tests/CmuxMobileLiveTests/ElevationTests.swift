import CmuxMobileAgentChat
import CryptoKit
import Foundation
import Testing
@testable import CmuxMobileLive

/// acpmux's sudo card on the phone (hub/elevation.rs): the records decode to the card, the
/// command reads as sudo gets it, a password never prints, and the signed bytes are the
/// approver payload acpmux checks (`Hub::card_answer_signed`: the card's id as the permission,
/// `card_provide`, the card's nonce, no answers).
@Suite struct ElevationTests {
    let records = AcpmuxRecords(sessionID: "s1")

    func json(_ string: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    @Test func recordsDecodeToTheCardAndItsClose() {
        let request = json(#"{"seq":3,"dir":"mux","kind":"elevation_request","msg":{"secretId":"c1","argv":["fs_usage","-w","-t","10"],"reason":"disk","host":"leos-mbp","timeoutSecs":20,"decisionNonce":"n1","personInstance":"i1"}}"#)
        let ask = AgentElevationAsk(id: "c1", argv: ["fs_usage", "-w", "-t", "10"], reason: "disk", host: "leos-mbp",
                                    timeoutSecs: 20, nonce: "n1", instance: "i1")
        #expect(records.map(request) == [.elevationRequest(ask)])
        let decision = json(#"{"seq":4,"dir":"mux","kind":"elevation_decision","msg":{"secretId":"c1","outcome":"approved"}}"#)
        #expect(records.map(decision) == [.elevationDecision(id: "c1")])
        // An acpmux without phone approval of sudo cards: no card a phone could not answer.
        let old = json(#"{"seq":5,"dir":"mux","kind":"elevation_request","msg":{"secretId":"c2","argv":["id"]}}"#)
        #expect(records.map(old).isEmpty)
    }

    /// The phone asks for the card's records on attach and live (acpmux sends a client only the
    /// kinds it names) from a Mac that serves the card; an older Mac refuses more than 8 kinds, so
    /// it gets the plain list.
    @Test @MainActor func theChatSubscribesToTheCardsRecordsOnlyWhereServed() {
        let with = AcpmuxSessionSource.chatKindsWithElevation.arrayValue ?? []
        #expect(with.contains(.string("elevation_request")))
        #expect(with.contains(.string("elevation_decision")))
        #expect(with.count <= 9)
        let plain = AcpmuxSessionSource.chatKinds.arrayValue ?? []
        #expect(plain.count <= 8)
        #expect(!plain.contains(.string("elevation_request")))
    }

    @Test func theCommandReadsAsSudoGetsIt() {
        let ask = AgentElevationAsk(id: "c", argv: ["echo", "a b", "it's", "/var/db"], reason: "", host: "",
                                    timeoutSecs: nil, nonce: "", instance: "")
        #expect(ask.commandLine == #"sudo echo 'a b' 'it'\''s' /var/db"#)
    }

    @Test func aPasswordNeverPrints() {
        let secret = AgentSecretText("hunter2-sentinel")
        let intent = AgentClientIntent.answerElevation(
            AgentElevationAsk(id: "c", argv: ["id"], reason: "", host: "", timeoutSecs: nil, nonce: "", instance: ""),
            password: secret)
        #expect(!String(describing: intent).contains("hunter2"))
        #expect(!String(reflecting: intent).contains("hunter2"))
        #expect(!"\(secret)".contains("hunter2"))
    }

    @Test @MainActor func theApproveIsSignedOverTheCard() {
        let payload = ApprovalPayload(
            instance: "i1", macDevice: "mac-1", approver: "phone-1", session: "s1", permission: "c1",
            option: AcpmuxHub.elevationOption, nonce: "n1", expiresAt: 1_760_000_000)
        let expected = Data("acpmux-approver-decision-v1\u{0}i1\u{0}mac-1\u{0}phone-1\u{0}s1\u{0}c1\u{0}card_provide\u{0}n1\u{0}1760000000\u{0}".utf8)
        #expect(payload.message == expected)
    }
}
