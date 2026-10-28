import AppKit
@testable import CmuxNextDesign
import Testing

/// The overlay change feed: an overlay host tells it when an overlay is presented, stops taking
/// the mouse or is dismissed; a subscription ends when its subscriber drops it.
/// Run: `swift test --filter OverlayChangeFeedTests`.
@MainActor @Suite(.serialized) struct OverlayChangeFeedTests {
    @Test func anOverlayHostSignalsPresentLeaveAndDismiss() async {
        let feed = OverlayChangeFeed()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = WindowOverlayHost.host(for: window)
        host.changes = feed
        var changes = feed.subscribe().makeAsyncIterator()
        let handle = host.present(NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20)),
                                                                 options: OverlayOptions(kind: .toast, passesThroughClicks: false))
        #expect(await changes.next() != nil, "present")
        handle.stopTakingMouse()
        #expect(await changes.next() != nil, "stop taking the mouse")
        handle.dismiss()
        #expect(await changes.next() != nil, "dismiss")
    }

    @Test func aSubscriptionEndsWithItsSubscriber() {
        let feed = OverlayChangeFeed()
        do {
            let stream = feed.subscribe()
            #expect(feed.subscriberCount == 1)
            withExtendedLifetime(stream) {}
        }
        #expect(feed.subscriberCount == 0)
    }
}
