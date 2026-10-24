import AppKit
@testable import CmuxNextDesign
import Testing

/// Design observers that moved from raw `addObserver(queue:)` blocks plus a deinit that removed
/// them to `MainActorObservation` tokens: they still see each notification in the post's own turn,
/// and they stop when their owner says so.
@MainActor
@Suite struct ObservationTokenSitesTests {
    /// A panel shown without the keys (the app is not active) hears another window of the app
    /// become key once, then stops watching; its own key change and a change after it is taken off
    /// screen do not count.
    @Test func anotherWindowTakingTheKeysReachesAPanelShownWithoutThemOnce() {
        let center = NotificationCenter()
        let panel = ActiveAppKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.nonactivatingPanel],
                                      backing: .buffered, defer: true, keyWindowNotifications: center)
        panel.isReleasedWhenClosed = false
        panel.isAppActive = { false }
        var elsewhere = 0
        panel.onKeyElsewhere = { elsewhere += 1 }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false

        panel.makeKey()
        #expect(!panel.isKeyWindow, "an inactive app's panel took the keys")
        center.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        #expect(elsewhere == 0, "the panel's own key change counted as another window's")
        center.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(elsewhere == 1, "another window becoming key did not reach the panel")
        center.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(elsewhere == 1, "the panel kept watching after it told its owner")

        panel.makeKey()
        panel.orderOut(nil)
        center.post(name: NSWindow.didBecomeKeyNotification, object: other)
        #expect(elsewhere == 1, "a panel taken off screen still heard key changes")
    }

    /// The elasticity follows the document's frame in the same turn as the change (AppKit posts
    /// frame changes on main, where the token's `queue: .main` handler runs inline), both ways.
    @Test func elasticityFollowsTheDocumentFrameInTheSameTurn() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        scroll.documentView = document
        scroll.tile()
        let fit = ScrollFitElasticity(scrollView: scroll)
        #expect(scroll.verticalScrollElasticity == .none, "a fitting document bounces")
        document.setFrameSize(NSSize(width: 200, height: 400))
        #expect(scroll.verticalScrollElasticity == .allowed, "an overflowing document does not bounce")
        document.setFrameSize(NSSize(width: 200, height: 40))
        #expect(scroll.verticalScrollElasticity == .none, "a document that fits again still bounces")
        withExtendedLifetime(fit) {}
    }
}
