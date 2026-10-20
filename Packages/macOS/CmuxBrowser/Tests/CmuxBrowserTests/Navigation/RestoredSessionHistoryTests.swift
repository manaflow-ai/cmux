import Foundation
import Testing
@testable import CmuxBrowser

@Suite("RestoredSessionHistory")
struct RestoredSessionHistoryTests {
    /// A sanitizer that treats `cmux-diff://` URLs as temporary, mirroring the
    /// app-side diff-viewer classification without depending on app types.
    private func makeSanitizer() -> SessionHistoryURLSanitizer {
        SessionHistoryURLSanitizer { url in
            url?.scheme?.lowercased() == "cmux-diff"
        }
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("restore activates replay and stores forward reversed")
    func restoreActivates() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        let became = history.restore(
            backHistoryURLStrings: ["https://a.test", "https://b.test"],
            forwardHistoryURLStrings: ["https://d.test", "https://e.test"],
            currentURLString: "https://c.test"
        )
        #expect(became)
        #expect(history.usesRestoredSessionHistory)
        #expect(history.back == [url("https://a.test"), url("https://b.test")])
        // forward stored nearest-forward-last
        #expect(history.forward == [url("https://e.test"), url("https://d.test")])
        #expect(history.current == url("https://c.test"))
    }

    @Test("restore with only temporary/empty entries does not activate")
    func restoreRejectsTemporary() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        let became = history.restore(
            backHistoryURLStrings: ["cmux-diff://token", "about:blank", "  "],
            forwardHistoryURLStrings: [],
            currentURLString: "cmux-diff://token"
        )
        #expect(!became)
        #expect(!history.usesRestoredSessionHistory)
        #expect(history.back.isEmpty)
        #expect(history.current == nil)
    }

    @Test("availability passes native flags through when inactive")
    func availabilityInactive() {
        let history = RestoredSessionHistory(sanitizer: makeSanitizer())
        #expect(history.availability(nativeCanGoBack: true, nativeCanGoForward: false)
            == NavigationAvailability(canGoBack: true, canGoForward: false))
    }

    @Test("availability ORs restored stacks with native flags when active")
    func availabilityActive() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test"],
            forwardHistoryURLStrings: [],
            currentURLString: "https://c.test"
        )
        #expect(history.availability(nativeCanGoBack: false, nativeCanGoForward: false)
            == NavigationAvailability(canGoBack: true, canGoForward: false))
        #expect(history.availability(nativeCanGoBack: false, nativeCanGoForward: true)
            == NavigationAvailability(canGoBack: true, canGoForward: true))
    }

    @Test("goBack pops restored back and pushes current to forward")
    func goBackPops() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test", "https://b.test"],
            forwardHistoryURLStrings: [],
            currentURLString: "https://c.test"
        )
        let decision = history.decideGoBack(
            isLiveAligned: true,
            nativeCanGoBack: false,
            resolvedCurrentURL: url("https://c.test")
        )
        #expect(decision == .navigate(url("https://b.test")))
        #expect(history.current == url("https://b.test"))
        #expect(history.back == [url("https://a.test")])
        #expect(history.forward == [url("https://c.test")])
    }

    @Test("goBack defers to native when not aligned and native can go back")
    func goBackNative() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test"],
            forwardHistoryURLStrings: [],
            currentURLString: "https://c.test"
        )
        let decision = history.decideGoBack(
            isLiveAligned: false,
            nativeCanGoBack: true,
            resolvedCurrentURL: url("https://c.test")
        )
        #expect(decision == .nativeGoBack)
        #expect(history.back == [url("https://a.test")])
    }

    @Test("goBack with empty stack and no native history refreshes only")
    func goBackRefreshOnly() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: ["https://d.test"],
            currentURLString: "https://c.test"
        )
        let decision = history.decideGoBack(
            isLiveAligned: true,
            nativeCanGoBack: false,
            resolvedCurrentURL: url("https://c.test")
        )
        #expect(decision == .refreshOnly)
    }

    @Test("goForward prefers native when available")
    func goForwardNative() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: ["https://d.test"],
            currentURLString: "https://c.test"
        )
        let decision = history.decideGoForward(
            nativeCanGoForward: true,
            resolvedCurrentURL: url("https://c.test")
        )
        #expect(decision == .nativeGoForward)
        #expect(history.forward == [url("https://d.test")])
    }

    @Test("goForward pops restored forward and pushes current to back")
    func goForwardPops() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: ["https://d.test", "https://e.test"],
            currentURLString: "https://c.test"
        )
        // forward stack: [e, d] (d is nearest-forward, last)
        let decision = history.decideGoForward(
            nativeCanGoForward: false,
            resolvedCurrentURL: url("https://c.test")
        )
        #expect(decision == .navigate(url("https://d.test")))
        #expect(history.current == url("https://d.test"))
        #expect(history.back == [url("https://c.test")])
        #expect(history.forward == [url("https://e.test")])
    }

    @Test("snapshot when aligned returns restored back and forward")
    func snapshotAligned() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test"],
            forwardHistoryURLStrings: ["https://d.test"],
            currentURLString: "https://c.test"
        )
        let snap = history.snapshot(
            nativeBackURLs: [url("https://native-b.test")],
            nativeForwardURLs: [url("https://native-f.test")],
            isLiveAligned: true
        )
        #expect(snap == SessionNavigationHistorySnapshot(
            backHistoryURLStrings: ["https://a.test"],
            forwardHistoryURLStrings: ["https://d.test"]
        ))
    }

    @Test("snapshot when not aligned concatenates restored back with native back")
    func snapshotMisaligned() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test"],
            forwardHistoryURLStrings: ["https://d.test"],
            currentURLString: "https://c.test"
        )
        let snap = history.snapshot(
            nativeBackURLs: [url("https://native-b.test")],
            nativeForwardURLs: [url("https://native-f.test")],
            isLiveAligned: false
        )
        #expect(snap == SessionNavigationHistorySnapshot(
            backHistoryURLStrings: ["https://a.test", "https://native-b.test"],
            forwardHistoryURLStrings: ["https://native-f.test"]
        ))
    }

    @Test("snapshot inactive returns native lists")
    func snapshotInactive() {
        let history = RestoredSessionHistory(sanitizer: makeSanitizer())
        let snap = history.snapshot(
            nativeBackURLs: [url("https://native-b.test")],
            nativeForwardURLs: [url("https://native-f.test")],
            isLiveAligned: true
        )
        #expect(snap == SessionNavigationHistorySnapshot(
            backHistoryURLStrings: ["https://native-b.test"],
            forwardHistoryURLStrings: ["https://native-f.test"]
        ))
    }

    @Test("realign moves entries after a back-list match into forward")
    func realignFromBack() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test", "https://b.test"],
            forwardHistoryURLStrings: [],
            currentURLString: "https://c.test"
        )
        // live navigated back to a.test
        let outcome = history.realign(toLiveCurrentURL: url("https://a.test"))
        #expect(outcome == .rebalanced)
        #expect(history.back.isEmpty)
        #expect(history.current == url("https://a.test"))
        // forward (nearest-last) should hold b then c: stored reversed -> [c, b]
        #expect(history.forward == [url("https://c.test"), url("https://b.test")])
    }

    @Test("realign clears stale forward when live current not found")
    func realignClearsForward() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test"],
            forwardHistoryURLStrings: ["https://d.test"],
            currentURLString: "https://c.test"
        )
        let outcome = history.realign(toLiveCurrentURL: url("https://elsewhere.test"))
        #expect(outcome == .clearedForward(liveCurrentString: "https://elsewhere.test"))
        #expect(history.forward.isEmpty)
    }

    @Test("realign is a no-op when already aligned")
    func realignNoChange() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test"],
            forwardHistoryURLStrings: [],
            currentURLString: "https://c.test"
        )
        let outcome = history.realign(toLiveCurrentURL: url("https://c.test"))
        #expect(outcome == .noChange)
    }

    @Test("abandon clears all restored state")
    func abandonClears() {
        var history = RestoredSessionHistory(sanitizer: makeSanitizer())
        history.restore(
            backHistoryURLStrings: ["https://a.test"],
            forwardHistoryURLStrings: ["https://d.test"],
            currentURLString: "https://c.test"
        )
        let abandoned = history.abandon()
        #expect(abandoned)
        #expect(!history.usesRestoredSessionHistory)
        #expect(history.back.isEmpty)
        #expect(history.forward.isEmpty)
        #expect(history.current == nil)
        // second abandon is a no-op
        let abandonedAgain = history.abandon()
        #expect(!abandonedAgain)
    }
}

@Suite("SessionHistoryURLSanitizer")
struct SessionHistoryURLSanitizerTests {
    private func makeSanitizer() -> SessionHistoryURLSanitizer {
        SessionHistoryURLSanitizer { $0?.scheme?.lowercased() == "cmux-diff" }
    }

    @Test("serializable rejects temporary, empty, and about:blank")
    func serializableRejects() {
        let s = makeSanitizer()
        #expect(s.serializableSessionHistoryURLString(URL(string: "cmux-diff://x")) == nil)
        #expect(s.serializableSessionHistoryURLString(URL(string: "about:blank")) == nil)
        #expect(s.serializableSessionHistoryURLString(nil) == nil)
        #expect(s.serializableSessionHistoryURLString(URL(string: "https://ok.test")) == "https://ok.test")
    }

    @Test("sanitized parses eligible strings only")
    func sanitizedParses() {
        let s = makeSanitizer()
        #expect(s.sanitizedSessionHistoryURL("  ") == nil)
        #expect(s.sanitizedSessionHistoryURL("about:blank") == nil)
        #expect(s.sanitizedSessionHistoryURL("cmux-diff://x") == nil)
        #expect(s.sanitizedSessionHistoryURL("https://ok.test") == URL(string: "https://ok.test"))
        #expect(s.sanitizedSessionHistoryURLs(["https://a.test", "about:blank", "https://b.test"])
            == [URL(string: "https://a.test")!, URL(string: "https://b.test")!])
    }
}
