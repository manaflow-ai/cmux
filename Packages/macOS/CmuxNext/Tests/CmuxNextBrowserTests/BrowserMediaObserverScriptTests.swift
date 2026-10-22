@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// The media hub's observer script (`BrowserMediaState.observerScript`), run for real in
/// JavaScriptCore against a small fake frame: its one-second timer runs only while the frame
/// has a report to keep or retry, so the many frames that never play (ads, embeds) have none.
@Suite struct BrowserMediaObserverScriptTests {
    /// A fake frame: `media` are its media elements; `fire` sends a capture-phase event.
    static let frame = """
    var window = this, top = this, frames = [], navigator = {}, location = { href: 'https://example.com/' };
    var posted = [], timeouts = [], intervals = {}, nextID = 1, listeners = {}, media = [];
    var setTimeout = function (f) { timeouts.push(f); return nextID++; };
    var setInterval = function (f) { var id = nextID++; intervals[id] = f; return id; };
    var clearInterval = function (id) { delete intervals[id]; };
    function flush() { for (var i = 0; i < 20 && timeouts.length; i++) { var t = timeouts; timeouts = []; t.forEach(function (f) { f(); }); } }
    function tick() { Object.keys(intervals).forEach(function (id) { if (intervals[id]) intervals[id](); }); flush(); }
    function timerCount() { return Object.keys(intervals).length; }
    function addEventListener(type, f) { (listeners[type] = listeners[type] || []).push(f); }
    function fire(type, target) { (listeners[type] || []).forEach(function (f) { f({ target: target }); }); flush(); }
    var document = { title: 'Song', pictureInPictureElement: null, addEventListener: function () {},
      querySelectorAll: function () { return media; } };
    function audio() {
      return { tagName: 'AUDIO', paused: false, ended: false, currentTime: 1, duration: 100, muted: false, volume: 1, playbackRate: 1 };
    }
    """

    static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(frame)
        context.evaluateScript(BrowserMediaState.observerScript(post: "posted.push(report)"))
        return context
    }

    @Test func aFrameThatNeverPlaysHasNoTimer() throws {
        let context = try Self.context()
        #expect(context.evaluateScript("timerCount()").toInt32() == 0)
        #expect(context.evaluateScript("posted.length").toInt32() == 0)
    }

    @Test func playingStartsTheTimerAndEndingStopsIt() throws {
        let context = try Self.context()
        context.evaluateScript("var song = audio(); media = [song]; fire('play', song);")
        #expect(context.evaluateScript("posted.length").toInt32() == 1)
        #expect(context.evaluateScript("timerCount()").toInt32() == 1)
        // The element leaves: the next tick reports null, the one after stops the timer.
        context.evaluateScript("media = []; tick(); tick();")
        #expect(context.evaluateScript("posted[posted.length - 1]").isNull)
        #expect(context.evaluateScript("timerCount()").toInt32() == 0)
    }

    @Test func aReportTheChannelWasNotReadyForIsRetried() throws {
        let context = try #require(JSContext())
        context.evaluateScript(Self.frame)
        context.evaluateScript("var ready = false;")
        context.evaluateScript(BrowserMediaState.observerScript(post: "posted.push(report)", ready: "ready"))
        context.evaluateScript("var song = audio(); media = [song]; fire('play', song);")
        #expect(context.evaluateScript("posted.length").toInt32() == 0)
        #expect(context.evaluateScript("timerCount()").toInt32() == 1)
        context.evaluateScript("ready = true; tick();")
        #expect(context.evaluateScript("posted.length").toInt32() == 1)
    }
}
