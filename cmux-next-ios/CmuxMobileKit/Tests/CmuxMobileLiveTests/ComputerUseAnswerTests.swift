#if os(iOS)
import CmuxMobileNotifications
import Foundation
import Testing
@testable import CmuxMobileLive

/// A Mac's Computer Use answer on the wire (docs/computer-use-approvals.md, "Phone wire (macOS)").
@Suite struct ComputerUseAnswerTests {
    @Test func theApprovalKeySignsTheNulJoinedMessage() {
        let message = LiveCoordinator.ComputerUseAnswer.signedMessage(phone: "phone-1", digest: "ab12", decision: "session", expiresAt: 1_793_400_120)
        #expect(message == Data("cmux-cu-phone-approval-v1\u{0}phone-1\u{0}ab12\u{0}session\u{0}1793400120".utf8))
    }

    @Test func theLinkParamsNameNoPhone() {
        var answer = LiveCoordinator.ComputerUseAnswer(mac: "m", macName: nil, digest: "ab12", decision: "deny", expiresAt: 10, signature: nil, phone: "p")
        #expect(answer.linkParams.keys.sorted() == ["decision", "digest", "expires_at"])
        answer.decision = "once"
        answer.signature = "00ff"
        #expect(answer.linkParams["signature"] as? String == "00ff" && answer.linkParams["phone"] == nil)
    }

    @Test func hostRefusalsAreSaidPlainly() {
        #expect(LiveCoordinator.computerUseRefusal(Data(#"{"ok":true}"#.utf8)) == nil)
        #expect(LiveCoordinator.computerUseRefusal(Data(#"{"ok":false,"error":{"code":"not_pending"}}"#.utf8))
            == LiveCoordinator.computerUseRefusalMessage("not_pending"))
        #expect(LiveCoordinator.computerUseRefusal(Data(#"{"error":"bad_signature"}"#.utf8))
            == LiveCoordinator.computerUseRefusalMessage("bad_signature"))
        #expect(LiveCoordinator.computerUseRefusalMessage("something") == LiveCoordinator.computerUseRefusalMessage(nil))
    }
}
#endif
