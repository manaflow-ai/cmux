import CmuxBrowser
import Foundation
import Testing

/// The media-playback hook is shared by both engines: WebKit posts through a
/// script message handler, Chromium through a DevTools binding that exists
/// only once the document's isolated world does.
struct BrowserMediaPlaybackScriptTests {
    @Test func webKitSourcePostsThroughItsHandlerWithoutWaiting() {
        let source = BrowserMediaPlaybackScript.source(
            post: "window.webkit.messageHandlers.cmuxMediaPlayback.postMessage(report)"
        )
        #expect(source.contains("window.webkit.messageHandlers.cmuxMediaPlayback.postMessage(report)"))
        #expect(source.contains("if (!(true)) return false;"))
    }

    @Test func chromiumSourceHoldsItsReportUntilTheBindingExists() {
        let source = BrowserMediaPlaybackScript.source(
            post: "cmuxMediaPlayback(JSON.stringify(report))",
            ready: "typeof cmuxMediaPlayback === 'function'"
        )
        #expect(source.contains("if (!(typeof cmuxMediaPlayback === 'function')) return false;"))
        #expect(source.contains("cmuxMediaPlayback(JSON.stringify(report))"))
        // A report that could not be sent is retried, not dropped.
        #expect(source.contains("retryReportLater()"))
    }

    @Test func reportParsesTheHookBody() throws {
        let report = try #require(BrowserMediaPlaybackReport(
            body: ["frameID": "f1", "playing": true, "audible": true, "pip": false]
        ))
        #expect(report == BrowserMediaPlaybackReport(frameID: "f1", isPlaying: true, isAudible: true))
        let quiet = try #require(BrowserMediaPlaybackReport(body: ["frameID": "f2", "playing": false]))
        #expect(!quiet.isAudible && !quiet.isPictureInPicture)
        #expect(BrowserMediaPlaybackReport(body: ["playing": true]) == nil)
        #expect(BrowserMediaPlaybackReport(body: ["frameID": "f3"]) == nil)
        #expect(BrowserMediaPlaybackReport(body: "nope") == nil)
    }

    @Test func reportParsesTheChromiumBindingPayload() throws {
        let report = try #require(BrowserMediaPlaybackReport(
            json: #"{"frameID":"main","playing":true,"audible":false,"pip":true}"#
        ))
        #expect(report == BrowserMediaPlaybackReport(
            frameID: "main", isPlaying: true, isAudible: false, isPictureInPicture: true
        ))
        #expect(BrowserMediaPlaybackReport(json: "not json") == nil)
    }

    @Test func chromiumMutesPageAudio() {
        #expect(BrowserEngineParityChecklist.standard.gaps(of: .chromium)["mediaMuting"] == nil)
    }
}
