@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// The media observer (`BrowserMediaState.observerScript`) runs from document start in every frame
/// of every page, in both engines. Idle must cost nothing (speed-of-sound-DESIGN.md 1,
/// idle-wakeups.md): a frame with nothing playing keeps no timer, so it never wakes its renderer.
/// It looks again every second only while something plays (metadata changes fire no event); a
/// report that waits for the binding keeps no timer and goes at the bridge's ready call. Run for
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
    var docListeners = {};
    var document = {
      title: 'A page', pictureInPictureElement: null, visibilityState: 'visible',
      addEventListener: function (type, f) { (docListeners[type] = docListeners[type] || []).push(f); },
      dispatchEvent: function (e) { (docListeners[e.type] || []).forEach(function (f) { f(e); }); return true; },
      querySelectorAll: function (s) { return /video|audio/.test(s) ? media : []; },
    };
    function CustomEvent(type, init) { this.type = type; this.detail = init ? init.detail : null; }
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
    /// The bridge's ready call after a binding add (`CEFDocumentCall.readyHook`).
    static let readyCall = "window.\(BrowserMediaState.readyHook)(); runTimeouts();"

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

    @Test func aReportTheBindingWasNotReadyForGoesAtTheReadyCall() throws {
        let context = try Self.context()
        context.evaluateScript("ready = false; var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 0)
        #expect(Self.timers(context) == 0)
        context.evaluateScript("ready = true; " + Self.readyCall)
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

    /// A same-document navigation (pushState) that removed the paused element: the tab's one
    /// look-again call sends null, so the card, whose Play button would do nothing, goes. Before,
    /// it stayed until the next media event or the next show.
    @Test func aLookAgainAfterASameDocumentNavigationRemovedThePausedElementReportsNull() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 1)
        context.evaluateScript("media = []; v.isConnected = false;")
        context.evaluateScript("document.dispatchEvent(new CustomEvent('cmux-media-look')); runTimeouts();")
        #expect(Self.posts(context) == 2, "the look-again call sent nothing")
        #expect(context.evaluateScript("lastReport() === null").toBool())
        #expect(Self.timers(context) == 0)
    }

    /// The tab's roll call (a frame detached): a frame that reported sends its report again,
    /// unchanged, so the tab knows it is still there; one that never reported stays quiet; and
    /// the call goes on to the child frames. No timer stays.
    @Test func aRollCallMakesAFrameThatReportedReportAgainAndReachesChildFrames() throws {
        let context = try Self.context()
        context.evaluateScript("var child = []; frames = { length: 1, 0: { postMessage: function (m) { child.push(m); } } };")
        context.evaluateScript("document.dispatchEvent(new CustomEvent('cmux-media-rollcall')); runTimeouts();")
        #expect(Self.posts(context) == 0, "a frame that never reported answered")
        context.evaluateScript("var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 1)
        context.evaluateScript(BrowserMediaState.rollCallScript + "; runTimeouts();")
        #expect(Self.posts(context) == 2, "the roll call got no answer")
        #expect(context.evaluateScript("lastReport().playing === false").toBool())
        #expect(context.evaluateScript("child.length === 2 && child[1].cmuxMediaRollCall === true").toBool())
        #expect(Self.timers(context) == 0)
        context.evaluateScript("fire('volumechange', v);")
        #expect(Self.posts(context) == 2, "the roll call's forced send stuck")
    }

    /// A frame whose binding never comes (an iframe made after the last binding add) keeps no
    /// retry timer; a ready call that finds the binding still missing sends nothing, and the next
    /// media event tries again. Before, its 1 s retry ticker ran for the life of the page.
    @Test func aReportWhoseBindingNeverComesKeepsNoTimer() throws {
        let context = try Self.context()
        context.evaluateScript("ready = false; var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.timers(context) == 0, "a waiting report keeps a retry ticker")
        for _ in 0..<30 { context.evaluateScript("tickSecond()") }
        context.evaluateScript(Self.readyCall)
        #expect(Self.timers(context) == 0)
        #expect(Self.posts(context) == 0)
        context.evaluateScript("ready = true; fire('volumechange', v);")
        #expect(Self.posts(context) == 1, "the next media event sends the held report")
    }

    /// A report the binding was not ready for keeps no timer, however long it waits: the bridge
    /// runs the observer's ready hook after each binding add, and the hook sends it. Before, a
    /// ten-look retry ticker gave up after 10 s, so an iframe player whose binding came with a
    /// later load event never showed its speaker icon (Chromium's DevTools path, forks before API 29).
    @Test func aWaitingReportKeepsNoTimerAndGoesAtTheReadyHookHoweverLate() throws {
        let context = try Self.context()
        context.evaluateScript("ready = false; var v = video(true); media = [v]; fire('play', v);")
        #expect(Self.posts(context) == 0)
        #expect(Self.timers(context) == 0, "a waiting report keeps a retry ticker")
        for _ in 0..<30 { context.evaluateScript("tickSecond()") }
        #expect(Self.posts(context) == 0)
        context.evaluateScript("ready = true; " + Self.readyCall)
        #expect(Self.posts(context) == 1, "the ready hook did not send the waiting report")
        #expect(context.evaluateScript("lastReport().playing === true").toBool())
    }

    /// The pagehide null that the binding was not ready for waits like every other report and
    /// goes at the ready call.
    @Test func aPagehideNullTheBindingWasNotReadyForGoesAtTheReadyCall() throws {
        let context = try Self.context()
        context.evaluateScript("var v = video(false); media = [v]; fire('pause', v);")
        #expect(Self.posts(context) == 1)
        context.evaluateScript("ready = false; fire('pagehide', {});")
        #expect(Self.posts(context) == 1)
        #expect(Self.timers(context) == 0)
        context.evaluateScript("ready = true; media = []; " + Self.readyCall)
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
