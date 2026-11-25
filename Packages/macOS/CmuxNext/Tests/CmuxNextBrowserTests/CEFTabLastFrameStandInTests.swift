import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A restored or woken Chromium tab shows its last picture over its new page until the page paints
/// (`BrowserWakeStandIn`; Leo 2026-11-22, constant rerenders on every page after a relaunch). The picture goes at the
/// page's first contentful paint after its commit, at the cap, and at a close. A restored page's own load refuses
/// downloads until a commit or a gesture (`refusesDownloadsUntilGesture`).
@MainActor @Suite(.serialized) struct CEFTabLastFrameStandInTests {
    private static func picture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        return try #require(context.makeImage())
    }

    private static func cover(of tab: CEFTab) -> BrowserPictureView? {
        tab.container.subviews.compactMap { $0 as? BrowserPictureView }.first
    }

    @Test func thePictureCoversThePageUntilItsFirstPaintAfterTheCommit() async throws {
        let rig = try CEFDevToolsStandInTests.Rig()
        let tab = try rig.attachedTab()
        defer { tab.close() }
        #expect(tab.showStandIn(try Self.picture(), decoded: true, cap: .seconds(3), clock: ManualClock()))
        #expect(tab.showsStandIn)
        #expect(Self.cover(of: tab) != nil, "the picture is a view over the page in the tab's container")
        #expect(tab.container.subviews.last === Self.cover(of: tab), "above the page")
        rig.runtime.handle(.loadStart(browser: CEFDevToolsStandInTests.Rig.browser, url: "https://example.com/", fromPost: false))
        #expect(tab.showsStandIn, "a commit alone draws nothing: the picture stays")
        tab.documentDidFirstPaint(contentful: false)
        #expect(tab.showsStandIn, "a frame with no content keeps it")
        tab.documentDidFirstPaint()
        #expect(!tab.showsStandIn)
        #expect(Self.cover(of: tab) == nil)
    }

    @Test func thePictureGoesAtTheCap() async throws {
        let rig = try CEFDevToolsStandInTests.Rig()
        let tab = try rig.attachedTab()
        defer { tab.close() }
        let clock = ManualClock()
        tab.showStandIn(try Self.picture(), decoded: false, cap: .seconds(3), clock: clock)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3))
        await rig.until { !tab.showsStandIn }
        #expect(!tab.showsStandIn, "a page that paints late shows itself loading, not a frozen picture")
    }

    @Test func aCloseTakesThePicture() throws {
        let rig = try CEFDevToolsStandInTests.Rig()
        let tab = try rig.attachedTab()
        tab.showStandIn(try Self.picture(), decoded: true, cap: .seconds(3), clock: ManualClock())
        tab.close()
        #expect(!tab.showsStandIn)
        #expect(!tab.showStandIn(try Self.picture(), decoded: true, cap: .seconds(3), clock: ManualClock()), "a closed tab shows none")
    }

    @Test func aRestoredPageRefusesDownloadsUntilACommitOrAGesture() throws {
        let rig = try CEFDevToolsStandInTests.Rig()
        let tab = try rig.attachedTab()
        defer { tab.close() }
        #expect(!tab.refusesDownloadsUntilGesture, "a page opened here downloads as ever")
        tab.refusesDownloadsUntilGesture = true
        rig.runtime.handle(.loadStart(browser: CEFDevToolsStandInTests.Rig.browser, url: "https://example.com/", fromPost: false))
        #expect(!tab.refusesDownloadsUntilGesture, "a page that committed is the user's page now")
        tab.refusesDownloadsUntilGesture = true
        tab.load(try #require(URL(string: "https://raw.githubusercontent.com/example/repo/main/clip.mp4")))
        #expect(!tab.refusesDownloadsUntilGesture, "a load the user starts downloads")
        tab.refusesDownloadsUntilGesture = true
        tab.reload()
        #expect(!tab.refusesDownloadsUntilGesture)
    }
}
