import CmuxNextFeed
import Testing

/// A report reply's id: the same reply sent again keeps it (a send past its deadline may have been
/// queued, and acpmux delivers one id once); another text or session is a new message.
@Suite struct ReportReplyIDTests {
    @Test func theSameReplySentAgainKeepsItsID() {
        let first = ReportReply(session: "s-1", text: "ok", retrying: nil, mint: { "a" })
        let again = ReportReply(session: "s-1", text: "ok", retrying: first, mint: { "b" })
        #expect(first.promptID == "a")
        #expect(again.promptID == "a", "a retry minted a new id, so acpmux would deliver it twice")
    }

    @Test func aChangedReplyGetsANewID() {
        let first = ReportReply(session: "s-1", text: "ok", retrying: nil, mint: { "a" })
        #expect(ReportReply(session: "s-1", text: "ok, done", retrying: first, mint: { "b" }).promptID == "b")
        #expect(ReportReply(session: "s-2", text: "ok", retrying: first, mint: { "c" }).promptID == "c")
    }
}
