import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A restored page's own load refuses downloads until a commit or a gesture (`refusesDownloadsUntilGesture`): its
/// address turned into a download in the run before, and every relaunch downloaded it again.
@MainActor @Suite(.serialized) struct CEFTabRestoredDownloadsTests {
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

    /// cmux#57419: a Chromium page that loads (committed, nothing painted yet) has nothing drawn over it: Chrome shows
    /// the page's background until it paints, never an older picture of it.
    @Test func aLoadingPageHasNoPictureOverIt() throws {
        let rig = try CEFDevToolsStandInTests.Rig()
        let tab = try rig.attachedTab()
        defer { tab.close() }
        rig.runtime.handle(.loadStart(browser: CEFDevToolsStandInTests.Rig.browser, url: "https://example.com/", fromPost: false))
        tab.documentDidFirstPaint(contentful: false)
        #expect(!tab.container.subviews.contains { ($0 as? NSImageView)?.image != nil || ($0.layer?.contents).map { CFGetTypeID($0 as CFTypeRef) == CGImage.typeID } == true })
    }
}
