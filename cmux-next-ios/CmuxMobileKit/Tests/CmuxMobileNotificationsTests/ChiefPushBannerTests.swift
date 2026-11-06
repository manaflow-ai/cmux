import Testing
@testable import CmuxMobileNotifications

/// One Chief notification per reply, the repliable one with clean text: the
/// Mac's push reads "Chief" with the message without Markdown, no session or
/// Mac subtitle, and keeps Reply (duplicate Chief notifications, 2026-10-30).
struct ChiefPushBannerTests {
    static let reply = PushPayload(mac: "m", macName: "Aziz's MacBook Pro", kind: .chief, agent: "Chief", workspace: "session",
                                   body: "You're **welcome**! See [a4](cmux://workspace/ws_1) and `code`.")

    @Test func chiefBannerIsCleanWithNoSubtitle() {
        let banner = PushBanner(payload: Self.reply)
        #expect(banner == PushBanner(title: "Chief", body: "You're welcome! See a4 and code."))
        #expect(banner.subtitle == nil)
    }

    @Test func chiefKeepsReplyInTheLongLook() {
        let actions = PushActions().extensionActions(for: Self.reply, replyField: true)
        #expect(actions?.map(\.identifier) == ["cmux.reply"])
    }

    @Test func otherKindsStillDropTheReplyButtonBesideTheField() {
        var done = Self.reply
        done.kind = .completed
        #expect(PushActions().extensionActions(for: done, replyField: true)?.isEmpty == true)
    }

    @Test func plainTextKeepsLineBreaks() {
        #expect(PushPlainText(markdown: "a *b*\nc").text == "a b\nc")
    }
}
