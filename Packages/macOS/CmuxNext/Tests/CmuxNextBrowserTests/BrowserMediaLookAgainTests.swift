@testable import CmuxNextBrowser
import Foundation
import Testing

/// When the tab asks the media observer to look again (``BrowserMediaState/looksAgain(from:to:)``):
/// once per same-document navigation of a page that shows media, never for an idle page or a new
/// load.
@Suite struct BrowserMediaLookAgainTests {
    static func states(media: BrowserMediaState?, phase: BrowserLoadPhase, to url: String) -> (BrowserTabState, BrowserTabState) {
        var before = BrowserTabState()
        before.url = URL(string: "https://example.com/watch")
        before.phase = phase
        before.media = media
        var after = before
        after.url = URL(string: url)
        return (before, after)
    }

    @Test func aPushStateOfAPageThatShowsMediaLooksAgain() {
        let (before, after) = Self.states(media: BrowserMediaFramesTests.paused, phase: .finished, to: "https://example.com/feed")
        #expect(BrowserMediaState.looksAgain(from: before, to: after))
    }

    @Test func anIdlePageOrTheSameAddressOrANewLoadDoesNot() {
        let idle = Self.states(media: nil, phase: .finished, to: "https://example.com/feed")
        #expect(!BrowserMediaState.looksAgain(from: idle.0, to: idle.1))
        let same = Self.states(media: BrowserMediaFramesTests.paused, phase: .finished, to: "https://example.com/watch")
        #expect(!BrowserMediaState.looksAgain(from: same.0, to: same.1))
        let load = Self.states(media: BrowserMediaFramesTests.paused, phase: .provisional, to: "https://example.org/")
        #expect(!BrowserMediaState.looksAgain(from: load.0, to: load.1))
    }

    /// The tab's call reaches the observer: it reports null once the element is gone.
    @Test func theLookAgainScriptMakesTheObserverReportNull() throws {
        let context = try BrowserMediaObserverIdleTests.context()
        context.evaluateScript("var v = video(false); media = [v]; fire('pause', v); media = []; v.isConnected = false;")
        context.evaluateScript(BrowserMediaState.lookAgainScript + "; runTimeouts();")
        #expect(BrowserMediaObserverIdleTests.posts(context) == 2)
        #expect(context.evaluateScript("lastReport() === null").toBool())
    }
}
