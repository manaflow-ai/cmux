import Testing
@testable import CmuxNextRemoteView

struct LatestFrameMailboxTests {
    @Test func latestFrameWinsAndOnlyOneDrainIsScheduled() {
        let mailbox = LatestFrameMailbox<Int>()
        #expect(mailbox.post(1))
        #expect(!mailbox.post(2))
        #expect(!mailbox.post(3))
        #expect(mailbox.take() == 3)
        #expect(mailbox.discardedCount == 2)
        #expect(mailbox.take() == nil)
        // After a drain, the next post schedules again.
        #expect(mailbox.post(4))
        #expect(mailbox.take() == 4)
        #expect(mailbox.discardedCount == 2)
    }

    @Test @MainActor func defaultPresenterIsMetal() {
        #expect(RemoteViewTunables().presenter.defaultValue == .metal)
        #expect(RemoteViewTunables().presenter.key == "remoteDesktop.debug.presenter")
    }
}
