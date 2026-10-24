@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// The media observer (`BrowserMediaState.observerScript`) runs from document start in every frame
/// of every page, in both engines. Idle must cost nothing (speed-of-sound-DESIGN.md 1,
/// idle-wakeups.md): a frame with nothing playing keeps no timer, so it never wakes its renderer.
/// It looks again every second only while something plays (metadata changes fire no event); a
/// report that waits for the channel keeps no timer and goes at the channel's ready call. Run for
/// real in JavaScriptCore against a small fake page.
@Suite struct BrowserMediaObserverIdleTests {
    /// A fake page: timers the test runs by hand, global and document listeners, media elements.
    static let page = """
    var intervals = new Map(), timeouts = [], nextTimer = 1, posted = [], listeners = {}, ready = true;
    function setInterval(f) { var id = nextTimer++; intervals.set(id, f); return id; }
    function clearInterval(id) { intervals.delete(id); }
    function setTimeout(f) { timeouts.push(f); return nextTimer++; }
    function runTimeouts() { for (var i = 0; i < 20 && timeouts.length; i++) { var t = timeouts; timeouts = []; t.forEach(function (f) { f(); }); } }
    function tickSecond() { Array.from(intervals.values()).forEach(function (f) { f(); }); runTimeouts(); }
    function addEventListener(type, f) { (listeners[type] = listeners[type] || []).push(f); }
    function fire(type, target) { (listeners[type] || []).forEach(function (f) { f({ type: type, target: target }); }); runTimeouts(); }
    var window = this, top = this, frames = { length: 0 }, navigator = {}, location = { href: 'https://example.com/' };
    var media = [];
    var document = {
      title: 'A page', pictureInPictureElement: null, visibilityState: 'visible', addEventListener: function () {},
      querySelectorAll: function (s) { return /video|audio/.test(s) ? media : []; },
    };
    function video(playing) {
      return { tagName: 'VIDEO', paused: !playing, ended: false, currentTime: 12, duration: 60, muted: false, volume: 1,
               playbackRate: 1, isConnected: true };
    }
    var observers = [], watched = [];
    function MutationObserver(f) { this.f = f; }
    MutationObserver.prototype.observe = function (target, options) {
      watched.push({ target: target, options: options || {} });
      if (observers.indexOf(this) < 0) observers.push(this);
    };
    MutationObserver.prototype.disconnect = function () { var self = this; observers = observers.filter(function (o) { return o !== self; }); };
    function mutate() { observers.slice().forEach(function (o) { o.f([]); }); runTimeouts(); }
    var body = { tagName: 'BODY', parentNode: document }, column = { tagName: 'DIV', parentNode: body };
    function readyCall() { return typeof window.__cmuxMediaReady === 'function' && window.__cmuxMediaReady(); }
    function lastReport() { return JSON.parse(posted[posted.length - 1]).report; }
    """

    static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("page script threw: \(exception?.toString() ?? "?")") }
        context.evaluateScript(page)
        context.evaluateScript(BrowserMediaState.observerScript(post: "posted.push(JSON.stringify(message))", ready: "ready"))
        context.evaluateScript("runTimeouts()")
        return context
    }

    static func timers(_ context: JSContext) -> Int32 { context.evaluateScript("intervals.size").toInt32() }
    static func posts(_ context: JSContext) -> Int32 { context.evaluateScript("posted.length").toInt32() }

    @Test func aFrameWithNothingPlayingKeepsNoTimer() throws {
        let context = try Self.context()
        #expect(Self.timers(context) == 0)
        for _ in 0..<5 { context.evaluateScript("tickSecond()") }
        #expect(Self.posts(context) == 0)
    }

    @Test func aPlayingElementIsLookedAtEverySecondUntilItPauses() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(true); media = [v]; fire('play', v);")
        #expect(Self.posts(context) == 1)
        #expect(Self.timers(context) == 1)
        // Every third look re-sends what plays (with its position, which may have drifted).
        for _ in 0..<3 { context.evaluateScript("tickSecond()") }
        #expect(Self.posts(context) == 2)
        context.evaluateScript("v.paused = true; fire('pause', v);")
        #expect(Self.posts(context) == 3)
        #expect(Self.timers(context) == 0)
        for _ in 0..<6 { context.evaluateScript("tickSecond()") }
        #expect(Self.posts(context) == 3)
    }

    /// A report the channel was not ready for keeps no timer; the channel's ready call (what
    /// `CEFMediaBridge` runs after each binding add) sends it.
    @Test func aReportTheBindingWasNotReadyForGoesAtTheReadyCallWithNoTimer() throws {
        let context = try Self.context()
        context.evaluateScript("ready = false; var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 0)
        #expect(Self.timers(context) == 0, "a waiting report keeps a retry ticker")
        context.evaluateScript("ready = true; readyCall(); runTimeouts();")
        #expect(Self.posts(context) == 1)
        #expect(Self.timers(context) == 0)
    }

    /// The race the ready call closes: a muted video autoplays before the binding reaches the
    /// observer's world, and the binding comes only when the page finishes, 15 s later, while
    /// the video keeps playing (no media event). Before, the observer retried ten times, one a
    /// second, then waited for a media event that never came: the tab never showed the media.
    @Test func aReportWhoseBindingComesAfterTenSecondsGoesOnceAtTheReadyCall() throws {
        let context = try Self.context()
        context.evaluateScript("ready = false; var v = video(true); v.muted = true; media = [v]; fire('play', v);")
        for _ in 0..<15 { context.evaluateScript("tickSecond()") }
        #expect(Self.posts(context) == 0)
        context.evaluateScript("ready = true; readyCall(); runTimeouts();")
        #expect(Self.posts(context) == 1, "the report never reaches the tab")
        #expect(context.evaluateScript("lastReport().playing === true && lastReport().muted === true").toBool())
        // From here it plays and is reported: the one-second look runs, as for any playing report.
        #expect(Self.timers(context) == 1)
    }

    @Test func nothingLeftPlayingReportsNullAndKeepsNoTimer() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(true); media = [v]; fire('play', v);")
        #expect(Self.timers(context) == 1)
        context.evaluateScript("media = []; v.ended = true; fire('emptied', v);")
        #expect(context.evaluateScript("lastReport() === null").toBool())
        #expect(Self.timers(context) == 0)
    }

    /// A page that removes its paused element (a single-page site swaps its route while the page
    /// stays shown): the element's events fire on a detached node, which the window's capture
    /// listeners never see. Before, the stale paused card stayed until the page was hidden and
    /// shown again. While a paused report is held, the observer watches the child lists of the
    /// element's ancestors only (no subtree, no document-wide watch), and drops that watch when
    /// the report clears or plays.
    @Test func aPausedElementThePageRemovesWhileShownReportsNullAtOnce() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(true); v.parentNode = column; media = [v]; fire('play', v);")
        #expect(context.evaluateScript("observers.length").toInt32() == 0, "a playing report keeps a DOM watch")
        context.evaluateScript("v.paused = true; fire('pause', v);")
        #expect(context.evaluateScript("lastReport().playing === false").toBool())
        #expect(Self.timers(context) == 0)
        #expect(context.evaluateScript("watched.every(function (w) { return w.options.childList === true && !w.options.subtree; })").toBool(),
                "the held element's watch reads more than its ancestors' child lists")
        #expect(context.evaluateScript("[column, body, document].every(function (n) { return watched.some(function (w) { return w.target === n; }); })").toBool())
        context.evaluateScript("media = []; v.isConnected = false; v.parentNode = null; mutate();")
        #expect(Self.posts(context) == 3, "a removed paused element keeps its stale report")
        #expect(context.evaluateScript("lastReport() === null").toBool())
        #expect(context.evaluateScript("observers.length").toInt32() == 0)
        #expect(Self.timers(context) == 0)
    }

    /// The watch on a held paused element costs nothing when the page changes something else:
    /// a sibling added beside it sends nothing and keeps the watch.
    @Test func otherChangesBesideAHeldPausedElementSendNothing() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(false); v.parentNode = column; media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 1)
        context.evaluateScript("mutate(); mutate();")
        #expect(Self.posts(context) == 1)
        #expect(context.evaluateScript("observers.length").toInt32() == 1)
    }

    /// The pagehide null that the binding was not ready for goes at the ready call like every
    /// other waiting report.
    @Test func aPagehideNullTheBindingWasNotReadyForGoesAtTheReadyCall() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 1)
        context.evaluateScript("ready = false; fire('pagehide', {});")
        #expect(Self.posts(context) == 1)
        #expect(Self.timers(context) == 0)
        context.evaluateScript("ready = true; media = []; readyCall(); runTimeouts();")
        #expect(Self.posts(context) == 2)
        #expect(context.evaluateScript("lastReport() === null").toBool())
        #expect(Self.timers(context) == 0)
    }

    /// Every message names its document, so the tab keeps one report per frame; a document that
    /// goes (navigation, its iframe removed) takes its report with it.
    @Test func reportsNameTheirFrameAndAGoingDocumentReportsNull() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(true); media = [v]; fire('play', v);")
        let frame = try #require(context.evaluateScript("JSON.parse(posted[0]).frame").toString())
        #expect(!frame.isEmpty && frame != "undefined")
        context.evaluateScript("fire('pagehide', {});")
        #expect(context.evaluateScript("lastReport() === null").toBool())
        #expect(context.evaluateScript("JSON.parse(posted[posted.length - 1]).frame").toString() == frame)
    }
}
