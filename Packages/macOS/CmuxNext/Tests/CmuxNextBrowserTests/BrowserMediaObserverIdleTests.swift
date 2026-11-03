@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// The media observer (`BrowserMediaState.observerScript`) runs from document start in every frame
/// of every page, in both engines. Idle must cost nothing (speed-of-sound-DESIGN.md 1,
/// idle-wakeups.md): a frame with nothing playing keeps no timer, so it never wakes its renderer.
/// It looks again every second only while something plays (metadata changes fire no event) or a
/// report waits for the binding. Run for real in JavaScriptCore against a small fake page.
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
    var observers = [];
    function MutationObserver(f) { this.f = f; }
    MutationObserver.prototype.observe = function () { observers.push(this); };
    MutationObserver.prototype.disconnect = function () { var self = this; observers = observers.filter(function (o) { return o !== self; }); };
    function mutate() { observers.slice().forEach(function (o) { o.f([]); }); runTimeouts(); }
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

    @Test func aReportTheBindingWasNotReadyForIsRetriedUntilItGoes() throws {
        let context = try Self.context()
        context.evaluateScript("ready = false; var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 0)
        #expect(Self.timers(context) == 1)
        context.evaluateScript("ready = true; tickSecond();")
        #expect(Self.posts(context) == 1)
        #expect(Self.timers(context) == 0)
    }

    @Test func nothingLeftPlayingReportsNullAndKeepsNoTimer() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(true); media = [v]; fire('play', v);")
        #expect(Self.timers(context) == 1)
        context.evaluateScript("media = []; v.ended = true; fire('emptied', v);")
        #expect(context.evaluateScript("lastReport() === null").toBool())
        #expect(Self.timers(context) == 0)
    }

    /// A page that removes its paused element: the element's pause and emptied events fire on a
    /// detached node, which the window's capture listeners never see. The observer keeps no DOM
    /// watch for it (a subtree MutationObserver on a busy page, a paused video left for hours,
    /// ran on every mutation batch, hidden or shown): the stale paused card goes at the next
    /// natural event, here the page showing again.
    @Test func aPausedElementThePageRemovesReportsNullAtTheNextShowWithNoDOMWatch() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(true); media = [v]; fire('play', v);")
        context.evaluateScript("v.paused = true; fire('pause', v);")
        #expect(context.evaluateScript("lastReport().playing === false").toBool())
        #expect(Self.timers(context) == 0)
        #expect(context.evaluateScript("observers.length").toInt32() == 0, "a paused report keeps a DOM watch")
        context.evaluateScript("media = []; v.isConnected = false; document.visibilityState = 'hidden'; fire('visibilitychange', document);")
        #expect(Self.posts(context) == 2, "a hidden page sends nothing")
        context.evaluateScript("document.visibilityState = 'visible'; fire('visibilitychange', document);")
        #expect(Self.posts(context) == 3)
        #expect(context.evaluateScript("lastReport() === null").toBool())
        #expect(context.evaluateScript("observers.length").toInt32() == 0)
    }

    /// A frame whose binding never comes (an iframe made after the last binding add) stops
    /// retrying after a bounded number of looks; the next media event tries again. Before, its
    /// 1 s retry ticker ran for the life of the page.
    @Test func aReportWhoseBindingNeverComesStopsRetrying() throws {
        let context = try Self.context()
        context.evaluateScript("ready = false; var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.timers(context) == 1)
        for _ in 0..<30 { context.evaluateScript("tickSecond()") }
        #expect(Self.timers(context) == 0, "the retry ticker runs for the life of the page")
        #expect(Self.posts(context) == 0)
        context.evaluateScript("ready = true; fire('volumechange', v);")
        #expect(Self.posts(context) == 1, "the next media event sends the held report")
    }

    /// The pagehide null that the binding was not ready for is retried like every other report.
    /// Before, only `report()` started the retry ticker, so that null never reached the tab.
    @Test func aPagehideNullTheBindingWasNotReadyForIsRetried() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 1)
        context.evaluateScript("ready = false; fire('pagehide', {});")
        #expect(Self.posts(context) == 1)
        #expect(Self.timers(context) == 1, "a pending null has no retry")
        context.evaluateScript("ready = true; media = []; tickSecond();")
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
