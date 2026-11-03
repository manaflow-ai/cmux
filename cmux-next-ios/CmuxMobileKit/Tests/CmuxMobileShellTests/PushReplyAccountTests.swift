#if os(iOS)
import CmuxMobileNotifications
import Testing
@testable import CmuxMobileShell

/// Replies are held across the app's lifetime, while the person can sign out
/// and sign in with another account in the same process.
@MainActor @Suite(.serialized)
struct PushReplyAccountTests {
    private func reply(_ mac: String) -> PushReply {
        PushReply(mac: mac, kind: .completed, sessionId: "s", action: .text("draft on \(mac)", attachments: []))
    }

    @Test func signOutClearsWaitingRepliesAndTheirNavigation() {
        let replies = PushReplies()
        let old = reply("mac-a")
        let router = NotificationRouter.shared
        router.set(NotificationRoute(kind: "completed", mac: "mac-a", sessionID: "s"))
        replies.enqueueForeground(old)
        #expect(replies.waiting == [old])
        #expect(router.pending?.mac == "mac-a")

        replies.signedOut()

        #expect(replies.waiting.isEmpty)
        #expect(router.pending == nil)
    }

    @Test func aPreviousAccountsOutboxReadCannotPopulateTheNextAccount() {
        let replies = PushReplies()
        let router = NotificationRouter.shared
        defer { replies.signedOut() }
        router.opened()

        // A read started under epoch 0, but its I/O finished after sign-out.
        replies.signedOut()
        replies.acceptOutbox([reply("mac-a")], epoch: 0)
        #expect(replies.waiting.isEmpty)
        #expect(router.pending == nil)

        // Only an outbox read belonging to this account can enqueue a reply.
        let current = reply("mac-b")
        replies.acceptOutbox([current], epoch: 1)
        #expect(replies.waiting == [current])
        #expect(router.pending?.mac == "mac-b")
    }
}
#endif
