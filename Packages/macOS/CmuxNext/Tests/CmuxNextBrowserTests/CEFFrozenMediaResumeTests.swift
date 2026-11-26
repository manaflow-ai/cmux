@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// A video that played in a hidden Chromium tab stayed paused after the tab came back (2026-11-25): Blink pauses
/// each playing media element when the hidden-tab freeze freezes its frame, and since M140 never plays it again.
/// `CEFDocumentScripts.frozenMediaResume` notes on `freeze` what plays and plays it again on `resume`. Run for real
/// in JavaScriptCore against a small fake page; `freeze()` does what Blink does: fires `freeze`, then pauses every
/// playing element without the page's `pause()` (`kFrameFrozen`), and `resume()` fires `resume`. The live check,
/// on a real tagged build, is `scripts/cmux-next/hidden-video-thaw-live.py`.
@Suite struct CEFFrozenMediaResumeTests {
    static let page = """
    var window = this, listeners = {}, documentListeners = {}, all = [];
    function addEventListener(type, f) { (listeners[type] = listeners[type] || []).push(f); }
    function HTMLMediaElement(connected) { this.paused = true; this.ended = false; this.isConnected = connected; this.plays = 0; }
    HTMLMediaElement.prototype.play = function () { this.paused = false; this.plays += 1; return Promise.resolve(); };
    HTMLMediaElement.prototype.pause = function () { this.paused = true; };
    function Element() {}
    Element.prototype.attachShadow = function () {
      var root = { listeners: {}, addEventListener: function (type, f) { (this.listeners[type] = this.listeners[type] || []).push(f); } };
      roots.push(root);
      return root;
    };
    var roots = [];
    var document = {
      addEventListener: function (type, f) { (documentListeners[type] = documentListeners[type] || []).push(f); },
      querySelectorAll: function () { return all.filter(function (e) { return e.isConnected && !e.inShadow; }); },
    };
    function media(connected) { var e = new HTMLMediaElement(connected); all.push(e); return e; }
    function fireDocument(type) { (documentListeners[type] || []).forEach(function (f) { f({ type: type }); }); }
    function fireWindow(type, init) { (listeners[type] || []).forEach(function (f) { f(Object.assign({ type: type }, init || {})); }); }
    // Blink: `freeze` first (the page's own handlers too), then each playing element pauses (kFrameFrozen).
    var pageFreeze = [];
    function freeze() {
      fireDocument('freeze');
      pageFreeze.forEach(function (f) { f(); });
      all.forEach(function (e) { if (!e.paused) e.paused = true; });
    }
    function resume() { fireDocument('resume'); }
    """

    static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("page script threw: \(exception?.toString() ?? "?")") }
        context.evaluateScript(page)
        context.evaluateScript(CEFDocumentScripts.frozenMediaResume)
        return context
    }

    static func flag(_ context: JSContext, _ expression: String) -> Bool { context.evaluateScript(expression).toBool() }

    /// The before: the freeze paused a playing muted video and nothing played it again.
    @Test func aVideoTheFreezePausedPlaysAgainOnResume() throws {
        let context = try Self.context()
        context.evaluateScript("var v = media(true); v.muted = true; v.play();")
        context.evaluateScript("freeze()")
        #expect(Self.flag(context, "v.paused"), "the fake freeze pauses it, as Blink does")
        context.evaluateScript("resume()")
        #expect(!Self.flag(context, "v.paused"), "the video the freeze paused stayed paused after resume")
    }

    @Test func aVideoThePagePausedBeforeTheFreezeStaysPaused() throws {
        let context = try Self.context()
        context.evaluateScript("var v = media(true); v.play(); v.pause(); freeze(); resume();")
        #expect(Self.flag(context, "v.paused"))
        #expect(context.evaluateScript("v.plays").toInt32() == 1)
    }

    /// A page that pauses its own video in its `freeze` handler (it runs after this script's, which was first).
    @Test func aVideoThePagePausesInItsOwnFreezeHandlerStaysPaused() throws {
        let context = try Self.context()
        context.evaluateScript("var v = media(true); v.play(); pageFreeze.push(function () { v.pause(); }); freeze(); resume();")
        #expect(Self.flag(context, "v.paused"))
    }

    /// Elements the document query cannot find: a detached element (`new Audio()`, a video never added) and a shadow
    /// root's element.
    @Test func detachedAndShadowRootElementsPlayAgain() throws {
        let context = try Self.context()
        context.evaluateScript("""
            var detached = media(false); detached.play();
            var root = new Element().attachShadow({ mode: 'closed' });
            var inner = media(true); inner.inShadow = true; inner.paused = false;
            root.listeners.play.forEach(function (f) { f({ target: inner }); });
            freeze(); resume();
            """)
        #expect(!Self.flag(context, "detached.paused"), "a detached element the freeze paused stayed paused")
        #expect(!Self.flag(context, "inner.paused"), "a shadow root's element the freeze paused stayed paused")
    }

    /// Chrome leaves media paused after the back/forward cache restores a page.
    @Test func nothingPlaysAgainAfterTheBackForwardCache() throws {
        let context = try Self.context()
        context.evaluateScript("var v = media(true); v.play(); fireWindow('pagehide', { persisted: true }); freeze(); resume(); fireWindow('pageshow', { persisted: true });")
        #expect(Self.flag(context, "v.paused"))
        // A later hidden-tab freeze of the restored page plays it again.
        context.evaluateScript("v.play(); freeze(); resume();")
        #expect(!Self.flag(context, "v.paused"))
    }

    /// An element the page took out of its document while frozen (in its freeze handler) stays paused.
    @Test func anElementRemovedMeanwhileStaysPaused() throws {
        let context = try Self.context()
        context.evaluateScript("var v = media(true); v.play(); pageFreeze.push(function () { v.isConnected = false; }); freeze(); resume();")
        #expect(Self.flag(context, "v.paused"))
    }

    /// Ended media and media that never played are left alone; a second freeze starts from what plays then.
    @Test func onlyWhatPlayedAtTheFreezeIsPlayedAgain() throws {
        let context = try Self.context()
        context.evaluateScript("var idle = media(true); var done = media(true); done.play(); done.ended = true; var v = media(true); v.play(); freeze(); resume();")
        #expect(Self.flag(context, "idle.paused") && context.evaluateScript("idle.plays").toInt32() == 0)
        #expect(context.evaluateScript("done.plays").toInt32() == 1)
        #expect(!Self.flag(context, "v.paused"))
        context.evaluateScript("v.pause(); freeze(); resume();")
        #expect(Self.flag(context, "v.paused"), "a video paused before the second freeze played again")
    }

    /// Both ways Chromium gets its document scripts (renderer path and DevTools) install it in the page's world, in
    /// every frame (an iframe's video freezes with its page).
    @Test func everyChromiumFrameGetsIt() {
        for post in [CEFDocumentScripts.Post.binding, .pageChannel] {
            let scripts = CEFDocumentScripts(post: post).media.filter { $0.source == CEFDocumentScripts.frozenMediaResume }
            #expect(scripts.count == 1)
            #expect(scripts.first?.world == "" && scripts.first?.allFrames == true)
        }
    }
}
