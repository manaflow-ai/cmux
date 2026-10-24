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
    var posted = [], timeouts = [], later = [], reads = 0, mutation = null, visibilityListeners = [];
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
      querySelector: function () { return null; },
    };
    Object.defineProperty(document.body, 'innerText', { get: function () { reads += 1; return text; } });
    function setVisibility(state) { document.visibilityState = state; visibilityListeners.forEach(function (f) { f(); }); runTimers(); }
    """

    static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("page script threw: \(exception?.toString() ?? "?")") }
        context.evaluateScript(page)
        context.evaluateScript(VerificationPageScripts.detectorScript(post: "posted.push(JSON.stringify(report))"))
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

    @Test func aPageThatDidNotChangeWhileHiddenIsNotReadWhenItShows() throws {
        let context = try Self.context()
        let atLoad = Self.reads(context)
        context.evaluateScript("setVisibility('hidden'); setVisibility('visible');")
        #expect(Self.reads(context) == atLoad)
    }
}
