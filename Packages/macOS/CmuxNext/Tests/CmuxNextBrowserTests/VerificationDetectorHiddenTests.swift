@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// The verification detector (`VerificationPageScripts.detectorScript`) runs in the top frame of
/// every https page in both engines and, for ten minutes after load, reads the page's whole text
/// (`document.body.innerText`: a forced style and layout pass) at most once a second whenever
/// the DOM changes. A hidden page (another tab, another workspace, a hidden app) is one nobody
/// types a code into, so its DOM changes (a clock, a feed, a chat) must cost no text read and no
/// timer there; the page is looked at once when it shows again. Idle must cost nothing
/// (speed-of-sound-DESIGN.md 1).
@Suite struct VerificationDetectorHiddenTests {
    /// A fake page that counts text reads and lets the test fire DOM changes and visibility changes.
    static let page = """
    var posted = [], timeouts = [], later = [], reads = 0, mutation = null, visibilityListeners = [], ready = true;
    // The ten-minute end of the offer window is kept apart: the test runs within it.
    var setTimeout = function (f, ms) { (ms >= 600000 ? later : timeouts).push(f); return timeouts.length + later.length; };
    function runTimers() { for (var i = 0; i < 20 && timeouts.length; i++) { var t = timeouts; timeouts = []; t.forEach(function (f) { f(); }); } }
    function MutationObserver(cb) { mutation = cb; }
    MutationObserver.prototype.observe = function () {};
    MutationObserver.prototype.disconnect = function () { mutation = null; };
    function mutate() { if (mutation) mutation([]); runTimers(); }
    var window = {}; window.top = window;
    var location = { protocol: 'https:' };
    var text = 'Welcome back. It is 10:00.';
    var document = {
      readyState: 'complete', documentElement: {}, visibilityState: 'visible',
      body: {},
      addEventListener: function (type, f) { if (type === 'visibilitychange') visibilityListeners.push(f); },
      removeEventListener: function (type, f) { visibilityListeners = visibilityListeners.filter(function (g) { return g !== f; }); },
      querySelector: function () { return null; },
    };
    Object.defineProperty(document.body, 'innerText', { get: function () { reads += 1; return text; } });
    function setVisibility(state) { document.visibilityState = state; visibilityListeners.forEach(function (f) { f(); }); runTimers(); }
    function endOfferWindow() { var l = later; later = []; l.forEach(function (f) { f(); }); }
    """

    static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("page script threw: \(exception?.toString() ?? "?")") }
        context.evaluateScript(page)
        context.evaluateScript(VerificationPageScripts.detectorScript(post: "posted.push(JSON.stringify(report))", ready: "ready"))
        context.evaluateScript("runTimers()")
        return context
    }

    /// A page that waits for a code while the channel is not there yet (Chromium's binding comes
    /// with an async DevTools call after the document commits, later on a slow page or a busy app).
    static func waitingBeforeTheChannel() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("page script threw: \(exception?.toString() ?? "?")") }
        context.evaluateScript(page)
        context.evaluateScript("ready = false; text = 'We sent a verification code to you@example.com';")
        context.evaluateScript(VerificationPageScripts.detectorScript(post: "posted.push(JSON.stringify(report))", ready: "ready"))
        context.evaluateScript("runTimers()")
        return context
    }

    static func reads(_ context: JSContext) -> Int32 { context.evaluateScript("reads").toInt32() }

    @Test func aShownPageIsReadOnItsChanges() throws {
        let context = try Self.context()
        let atLoad = Self.reads(context)
        #expect(atLoad == 1)
        context.evaluateScript("text = 'It is 10:01.'; mutate();")
        #expect(Self.reads(context) == atLoad + 1)
    }

    @Test func aHiddenPageIsNotReadWhileItChanges() throws {
        let context = try Self.context()
        let atLoad = Self.reads(context)
        context.evaluateScript("setVisibility('hidden');")
        for minute in 1...30 { context.evaluateScript("text = 'It is 10:\(minute).'; mutate();") }
        #expect(Self.reads(context) == atLoad)
        #expect(context.evaluateScript("timeouts.length").toInt32() == 0)
    }

    @Test func aPageThatChangedWhileHiddenIsReadOnceWhenItShows() throws {
        let context = try Self.context()
        let atLoad = Self.reads(context)
        context.evaluateScript("setVisibility('hidden');")
        context.evaluateScript("text = 'We sent a verification code to you@example.com'; mutate(); mutate();")
        context.evaluateScript("setVisibility('visible');")
        #expect(Self.reads(context) == atLoad + 1)
        #expect(context.evaluateScript("posted.length").toInt32() == 1)
    }

    /// Before, a missing channel was retried every 250 ms and given up after 10 s for the rest
    /// of the document; a binding that came later (slow load, busy app) never got the report, and
    /// the observer still read the whole page text on every DOM change for 10 minutes. Now the
    /// waiting page keeps no timer and reads no text; the channel's ready call reports.
    @Test func aChannelThatComesLateStillGetsTheReportWithNoTimerMeanwhile() throws {
        let context = try Self.waitingBeforeTheChannel()
        #expect(context.evaluateScript("posted.length").toInt32() == 0)
        #expect(context.evaluateScript("timeouts.length").toInt32() == 0, "a timer waits for the channel")
        let reads = Self.reads(context)
        for minute in 1...5 { context.evaluateScript("text = 'We sent a code. It is 10:0\(minute).'; mutate();") }
        #expect(Self.reads(context) == reads, "a page already found waiting is read again")
        context.evaluateScript("ready = true; window.\(VerificationPageScripts.readyHook)(); runTimers();")
        #expect(context.evaluateScript("posted.length").toInt32() == 1)
        context.evaluateScript("window.\(VerificationPageScripts.readyHook)(); setVisibility('hidden'); setVisibility('visible');")
        #expect(context.evaluateScript("posted.length").toInt32() == 1, "reports once per document")
    }

    @Test func aChannelThatComesLateReportsAtTheNextShowWithoutItsReadyCall() throws {
        let context = try Self.waitingBeforeTheChannel()
        context.evaluateScript("ready = true; setVisibility('hidden'); setVisibility('visible');")
        #expect(context.evaluateScript("posted.length").toInt32() == 1)
    }

    /// The offer window ends for good after 10 minutes: a page that changed while hidden and shows
    /// after that is not read and does not report, and nothing is left listening.
    @Test func nothingReportsOrListensAfterTheOfferWindow() throws {
        let context = try Self.context()
        let atLoad = Self.reads(context)
        context.evaluateScript("setVisibility('hidden');")
        context.evaluateScript("text = 'We sent a verification code to you@example.com'; mutate();")
        context.evaluateScript("endOfferWindow(); setVisibility('visible');")
        #expect(Self.reads(context) == atLoad)
        #expect(context.evaluateScript("posted.length").toInt32() == 0)
        #expect(context.evaluateScript("visibilityListeners.length").toInt32() == 0)
        #expect(context.evaluateScript("mutation === null").toBool())
    }

    @Test func aPageThatDidNotChangeWhileHiddenIsNotReadWhenItShows() throws {
        let context = try Self.context()
        let atLoad = Self.reads(context)
        context.evaluateScript("setVisibility('hidden'); setVisibility('visible');")
        #expect(Self.reads(context) == atLoad)
    }
}
