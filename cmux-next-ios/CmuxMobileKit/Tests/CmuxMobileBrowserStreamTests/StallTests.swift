import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

/// The 2026-10-24 freeze (cmux-next-ios/verify/browser-freeze.md): a shown
/// page whose stream stopped kept its last frame and took touches that went
/// nowhere. The watchdog asks for a keyframe, restarts the decoder, then
/// opens the stream again and says "Reconnecting browser…".
@Suite struct StallWatchdogTests {
    let t0 = ContinuousClock.now

    func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .milliseconds(Int(seconds * 1000)) }

    @Test func aStillPageIsProbedThenRestartedThenReopened() {
        var dog = BrowserStallWatchdog()
        dog.start(at: at(0))
        dog.pictureShown(at: at(1))
        #expect(dog.check(at: at(9)) == .none, "a still page sends nothing; that alone is no stall")
        #expect(dog.check(at: at(11)) == .askKeyframe)
        #expect(dog.check(at: at(12)) == .none)
        #expect(dog.check(at: at(14)) == .restartDecoder)
        #expect(dog.check(at: at(15)) == .none, "the decoder restarts once")
        #expect(dog.check(at: at(17)) == .reopen)
        // The model stops it while the stream opens again.
        dog.stop()
        #expect(!dog.watching)
        #expect(dog.check(at: at(30)) == .none)
    }

    @Test func aPictureAnswersTheProbe() {
        var dog = BrowserStallWatchdog()
        dog.start(at: at(0))
        #expect(dog.check(at: at(10)) == .askKeyframe)
        dog.pictureShown(at: at(10.2))
        #expect(dog.check(at: at(14)) == .none)
        #expect(dog.check(at: at(19)) == .none)
        #expect(dog.check(at: at(20.2)) == .askKeyframe, "probed again only after another idle stretch")
    }

    @Test func inputWithNoPictureIsProbedSooner() {
        var dog = BrowserStallWatchdog()
        dog.start(at: at(0))
        dog.pictureShown(at: at(1))
        dog.inputSent(at: at(2))
        #expect(dog.check(at: at(3.5)) == .none)
        #expect(dog.check(at: at(4)) == .askKeyframe)
    }

    @Test func theDecodersOwnRequestIsWatched() {
        var dog = BrowserStallWatchdog()
        dog.start(at: at(0))
        dog.pictureShown(at: at(1))
        dog.keyframeAsked(at: at(2))
        #expect(dog.check(at: at(5)) == .restartDecoder)
        #expect(dog.check(at: at(8)) == .reopen)
    }

    @Test func nothingHappensWhileNotWatching() {
        var dog = BrowserStallWatchdog()
        dog.keyframeAsked(at: at(0))
        dog.inputSent(at: at(0))
        #expect(dog.check(at: at(60)) == .none)
    }
}

@MainActor @Suite struct StallModelTests {
    func settle() async { for _ in 0..<40 { await Task.yield() } }

    func until(_ check: () -> Bool) async {
        for _ in 0..<200 where !check() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A shown, welcomed page with no ticking watchdog (the test looks itself).
    func shownPage() async throws -> (StreamedBrowserModel, FakeOpener) {
        let opener = FakeOpener()
        let model = StreamedBrowserModel(tab: "s7", url: URL(string: "https://example.com/")) { sink, tab, url in
            try await opener.openBrowser(tab: tab, url: url?.absoluteString, sink: sink)
        }
        model.watchdogTick = { throw CancellationError() }
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        await until { opener.sink("s7") != nil }
        await settle()
        opener.sink("s7")?.browserMessage(Data(#"{"t":"welcome","caps":["input.service"]}"#.utf8))
        await settle()
        return (model, opener)
    }

    @Test func aPageWithNoPictureAfterAKeyframeRequestOpensAgainAndSaysSo() async throws {
        let (model, opener) = try await shownPage()
        let first = try #require(opener.stream("s7"))
        let now = ContinuousClock.now
        model.checkStall(at: now + .seconds(11))
        #expect(first.keyframes == 1, "a still page is probed with a keyframe request")
        model.checkStall(at: now + .seconds(15))
        #expect(first.keyframes == 2, "unanswered: the decoder restarts and asks again")
        model.checkStall(at: now + .seconds(18))
        await until { opener.tabs.count == 2 }
        #expect(first.isClosed)
        #expect(opener.tabs == ["s7", "s7"])
        #expect(model.phase == .waiting(StreamedBrowserModel.reconnectingText))
    }

    @Test func aStreamTheLibraryEndedAsStalledReconnects() async throws {
        let (model, opener) = try await shownPage()
        opener.sink("s7")?.browserClosed(code: "stalled", reason: "the page stopped answering input")
        await until { opener.tabs.count == 2 }
        #expect(opener.tabs == ["s7", "s7"])
        #expect(model.phase == .waiting(StreamedBrowserModel.reconnectingText))
    }

    @Test func aPageThatKeepsStallingStopsAndOffersReopen() async throws {
        let (model, opener) = try await shownPage()
        for round in 1...StreamedBrowserModel.maxStallReconnects {
            opener.sink("s7")?.browserClosed(code: "stalled", reason: "")
            await until { opener.tabs.count == round + 1 }
            #expect(model.phase == .waiting(StreamedBrowserModel.reconnectingText))
            await settle()
            opener.sink("s7")?.browserMessage(Data(#"{"t":"welcome","caps":["input.service"]}"#.utf8))
            await settle()
        }
        opener.sink("s7")?.browserClosed(code: "stalled", reason: "")
        await settle()
        #expect(opener.tabs.count == StreamedBrowserModel.maxStallReconnects + 1, "no endless cycle")
        #expect(model.canReopen)
        model.reopen()
        await until { opener.tabs.count == StreamedBrowserModel.maxStallReconnects + 2 }
        #expect(opener.tabs.count == StreamedBrowserModel.maxStallReconnects + 2)
    }

    /// The rig's 05:02:31 hang: the Mac's browser host crashed, hostd ended
    /// the stream (`eof`) while the link stayed up, and the shown page waited
    /// for a new link that never came ("Reconnecting to the Mac…" for good).
    @Test func aShownPageWhoseMacStreamEndedOpensAgain() async throws {
        let (model, opener) = try await shownPage()
        opener.sink("s7")?.browserClosed(code: "eof", reason: "")
        await until { opener.tabs.count == 2 }
        #expect(opener.tabs == ["s7", "s7"])
        #expect(model.phase == .waiting(StreamedBrowserModel.reconnectingText))
        #expect(StreamedBrowserModel.afterClose(code: "eof", shown: false, autoReopens: 0) == .waitForView)
        #expect(StreamedBrowserModel.afterClose(code: "link_closed", shown: true, autoReopens: 0) == .waitForLink)
    }

    @Test func aHiddenStalledPageWaitsUntilShown() {
        #expect(StreamedBrowserModel.afterClose(code: "stalled", shown: false, autoReopens: 0) == .waitForView)
        #expect(StreamedBrowserModel.afterClose(code: "stalled", shown: true, autoReopens: 5) == .reconnect)
    }
}
