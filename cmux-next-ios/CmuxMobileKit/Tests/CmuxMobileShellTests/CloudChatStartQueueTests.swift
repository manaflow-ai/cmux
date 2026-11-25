#if os(iOS)
import Testing
@testable import CmuxMobileShell

/// New Chat on a Cloud machine is not grayed out while its relay connects: a tap waits for the
/// hub and starts the chat once it is ready (Leo, 2026-11-24: "the entire thing is somehow grayed
/// out and I can't interact with anything at all"). Before, the button was disabled until then.
@Suite struct CloudChatStartQueueTests {
    @Test func aTapOnAReadyHubStartsAtOnce() {
        var queue = CloudChatStartQueue()
        #expect(queue.tap(ready: true, starting: false) == .start)
        #expect(!queue.queued)
    }

    @Test func aTapWhileConnectingWaitsThenStartsOnceReady() {
        var queue = CloudChatStartQueue()
        #expect(queue.tap(ready: false, starting: false) == .none)
        #expect(queue.queued)
        // Still connecting: nothing yet, the tap is kept.
        #expect(queue.link(ready: false, failed: false) == .none)
        #expect(queue.queued)
        #expect(queue.link(ready: true, failed: false) == .start)
        #expect(!queue.queued)
        // Started once: a later change starts nothing.
        #expect(queue.link(ready: true, failed: false) == .none)
    }

    @Test func aFailedConnectDropsTheWaitingTap() {
        var queue = CloudChatStartQueue()
        _ = queue.tap(ready: false, starting: false)
        #expect(queue.link(ready: false, failed: true) == .dropped)
        #expect(!queue.queued)
        #expect(queue.link(ready: true, failed: false) == .none)
    }

    @Test func repeatedTapsAreOneRequest() {
        var queue = CloudChatStartQueue()
        _ = queue.tap(ready: false, starting: false)
        #expect(queue.tap(ready: false, starting: false) == .none)
        #expect(queue.tap(ready: true, starting: false) == .none)
        #expect(queue.link(ready: true, failed: false) == .start)
        #expect(queue.tap(ready: true, starting: true) == .none)
    }

    @Test func noLinkChangeStartsAChatNobodyAskedFor() {
        var queue = CloudChatStartQueue()
        #expect(queue.link(ready: true, failed: false) == .none)
        #expect(queue.link(ready: false, failed: true) == .none)
    }
}
#endif
