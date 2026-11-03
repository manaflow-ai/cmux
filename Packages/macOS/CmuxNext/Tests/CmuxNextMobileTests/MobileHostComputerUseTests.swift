import Foundation
import Testing
@testable import CmuxNextMobile

/// Computer Use approvals on the iPhone host's control lines (docs/computer-use-approvals.md,
/// "Phone wire").
@Suite struct MobileHostComputerUseTests {
    @Test func parsesAPhoneAnswer() {
        let digest = String(repeating: "d", count: 64)
        #expect(MobileHostEvent(line: #"{"type":"cu_approval_answer","phone_device_id":"p","digest":"\#(digest)","decision":"once","expires_at":1793400120,"signature":"ab"}"#)
            == .computerUseAnswer(MobileHostComputerUseAnswer(phoneDeviceID: "p", digest: digest, decision: "once", expiresAt: 1_793_400_120, signature: "ab")))
        #expect(MobileHostEvent(line: #"{"type":"cu_approval_answer","phone_device_id":"p","digest":"x","decision":"deny","expires_at":1}"#)
            == .computerUseAnswer(MobileHostComputerUseAnswer(phoneDeviceID: "p", digest: "x", decision: "deny", expiresAt: 1, signature: nil)))
        #expect(MobileHostEvent(line: #"{"type":"cu_approval_answer","digest":"x","decision":"deny","expires_at":1}"#) == nil)
    }

    @Test func askAndDoneLines() throws {
        let ask = try #require(try JSONSerialization.jsonObject(with: MobileHostLaunch.computerUseApprovalLine(request: ["digest": "d", "v": 1], always: true)) as? [String: Any])
        #expect(ask["type"] as? String == "cu_approval")
        #expect(ask["always"] as? Bool == true)
        #expect((ask["request"] as? [String: Any])?["digest"] as? String == "d")
        let done = MobileHostLaunch.computerUseApprovalDoneLine(digest: "d")
        #expect(String(decoding: done, as: UTF8.self) == "{\"digest\":\"d\",\"type\":\"cu_approval_done\"}\n")
    }

    @Test func aPhoneAnswerChangesNoState() {
        var state = MobileHostState()
        let before = state
        state.apply(.computerUseAnswer(MobileHostComputerUseAnswer(phoneDeviceID: "p", digest: "d", decision: "deny", expiresAt: 1, signature: nil)), at: Date())
        #expect(state == before)
    }
}
