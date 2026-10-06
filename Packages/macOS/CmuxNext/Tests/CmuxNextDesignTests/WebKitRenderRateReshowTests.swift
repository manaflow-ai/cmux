import AppKit
import Testing
import WebKit
@testable import CmuxNextDesign

/// The shared re-show that applies a live render-rate change: its two steps
/// run on the owner's clock, and a newer re-show or the owner's going away
/// cancels it without leaving the page hidden or covered.
@MainActor
@Suite struct WebKitRenderRateReshowTests {
    private func page() -> (host: NSView, webView: WKWebView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let webView = WKWebView(frame: host.bounds, configuration: WKWebViewConfiguration())
        host.addSubview(webView)
        return (host, webView)
    }

    private static func covers(_ host: NSView) -> Int {
        host.subviews.filter { $0 is NSImageView }.count
    }

    @Test func theCoverStaysUntilBothStepsPassOnTheClock() async {
        let (host, webView) = page()
        let clock = ManualClock()
        let task = WebKitRenderRate.reshow(webView, replacing: nil, snapshot: { NSImage(size: NSSize(width: 4, height: 3)) },
                                           clock: clock)
        await clock.sleepers(atLeast: 1)
        #expect(webView.isHidden)
        #expect(Self.covers(host) == 1)
        clock.advance(by: .milliseconds(33))
        await clock.sleepers(atLeast: 1)
        #expect(!webView.isHidden, "shown after 33 ms")
        #expect(Self.covers(host) == 1, "covered while the shown page paints")
        clock.advance(by: .milliseconds(50))
        await task.value
        #expect(!webView.isHidden)
        #expect(Self.covers(host) == 0)
    }

    @Test func aNewerReshowCancelsTheRunningOne() async {
        let (host, webView) = page()
        let clock = ManualClock()
        var snapshots = 0
        let snapshot: () async -> NSImage? = {
            snapshots += 1
            return NSImage(size: NSSize(width: 4, height: 3))
        }
        let first = WebKitRenderRate.reshow(webView, replacing: nil, snapshot: snapshot, clock: clock)
        await clock.sleepers(atLeast: 1)
        #expect(webView.isHidden)
        let second = WebKitRenderRate.reshow(webView, replacing: first, snapshot: snapshot, clock: clock)
        await first.value
        #expect(first.isCancelled)
        // The cancelled re-show showed the page and took its cover away
        // before the newer one began.
        await clock.sleepers(atLeast: 1)
        #expect(snapshots == 2)
        #expect(webView.isHidden)
        #expect(Self.covers(host) == 1, "only the newer re-show's cover")
        clock.advance(by: .milliseconds(33))
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .milliseconds(50))
        await second.value
        #expect(!webView.isHidden)
        #expect(Self.covers(host) == 0)
    }

    @Test func cancellingWhenTheOwnerGoesAwayShowsThePageAndRemovesTheCover() async {
        let (host, webView) = page()
        let clock = ManualClock()
        let task = WebKitRenderRate.reshow(webView, replacing: nil, snapshot: { NSImage(size: NSSize(width: 4, height: 3)) },
                                           clock: clock)
        await clock.sleepers(atLeast: 1)
        task.cancel()
        await task.value
        #expect(!webView.isHidden)
        #expect(Self.covers(host) == 0)
    }
}
