import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Testing

/// The cloud area's reply caller of the Rust rules (`cloud.reply_classify`) over the FFI. The
/// rule's cases are the Rust tests (cmux-home-rules `tests/cloud_home.rs`, `tests/cloud_link.rs`); the link's
/// `cloud.link_step` runs end to end in `CloudServerChoiceTests`.
@Suite struct CloudReplyRulesSmokeTests {
    @Test func aDaemonReplyReadsThroughTheRules() {
        let expired = CloudReplyError(DaemonError.command(cmd: "cloud-op", message: "expired", code: "cloud_session_expired"))
        #expect(expired.isNoLease)
        #expect(expired.rejection == .ownerUnreachable)

        let forbidden = CloudReplyError(DaemonError.command(cmd: "cloud-op", message: "no", code: "cloud_conversation_rejected",
                                                            details: .object(["reason": .string("forbidden")])))
        #expect(!forbidden.isNoLease)
        #expect(forbidden.rejection == .notAuthorized)

        #expect(CloudReplyError(HomeRejection.rateLimited(retryAfter: 2)).rejection == .rateLimited(retryAfter: 2))
        #expect(CloudReplyError(CancellationError()).rejection == .indeterminate)
    }
}
