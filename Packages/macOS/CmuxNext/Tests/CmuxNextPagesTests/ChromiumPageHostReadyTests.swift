import CmuxNextPages
import Foundation
import JavaScriptCore
import Testing

/// Posts a cmux page makes before its transport exists wait for the transport's readiness, never for a timer: the
/// DevTools binding arriving on the page (V8's `Runtime.addBinding` sets the global, so a setter sees it), or the page
/// channel's relay announcing itself (``ChromiumPageHostBridge/readyEvent(for:)``). None is ever dropped.
@Suite struct ChromiumPageHostReadyTests {
    /// A context with no transport yet, whose `setTimeout` only counts its calls (a poll would show there).
    private func context(withDocument: Bool = false) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var timers = 0;
        var setTimeout = function () { timers += 1; };
        var posted = [];
        """)
        if withDocument {
            context.evaluateScript("""
            var listeners = [];
            var document = {
              addEventListener: function (type, listener) { listeners.push({ type: type, listener: listener }); },
              dispatchEvent: function (event) {
                for (var i = 0; i < listeners.length; i++) if (listeners[i].type === event.type) listeners[i].listener(event);
                return !event.defaultPrevented;
              },
            };
            var CustomEvent = function (type, init) {
              this.type = type; this.detail = init.detail; this.defaultPrevented = false;
              this.preventDefault = function () { this.defaultPrevented = true; };
            };
            """)
        }
        return context
    }

    @Test func aPostBeforeTheBindingLeavesWhenTheBindingArrivesWithNoTimer() throws {
        let context = try context()
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: ["log"]))
        context.evaluateScript("webkit.messageHandlers.log.postMessage({n: 1}); webkit.messageHandlers.log.postMessage({n: 2});")
        #expect(context.evaluateScript("posted.length").toInt32() == 0, "a post left with no transport")
        // Much later than the old 2 s give-up, the binding arrives the way V8's Runtime.addBinding installs it.
        context.evaluateScript("globalThis.\(ChromiumPageHostBridge.bindingName) = function (text) { posted.push(text); };")
        #expect(exception == nil)
        let posted = try #require(context.evaluateScript("JSON.stringify(posted.map(function (t) { return JSON.parse(t); }))").toString())
        #expect(posted.contains("\"n\":1") && posted.contains("\"n\":2"), "the waiting posts did not leave on arrival: \(posted)")
        #expect(posted.range(of: "\"n\":1")!.lowerBound < posted.range(of: "\"n\":2")!.lowerBound, "posts left out of order")
        #expect(context.evaluateScript("timers").toInt32() == 0, "the page polled a timer while it waited")
        // Later posts go straight out on the binding.
        context.evaluateScript("webkit.messageHandlers.log.postMessage({n: 3});")
        #expect(context.evaluateScript("posted.length").toInt32() >= 2)
        #expect(context.evaluateScript("posted[posted.length - 1]").toString().contains("\"n\":3"))
    }

    @Test func aBindingAlreadyThereNeedsNoWait() throws {
        let context = try context()
        context.evaluateScript("var \(ChromiumPageHostBridge.bindingName) = function (text) { posted.push(text); };")
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: ["log"]))
        context.evaluateScript("webkit.messageHandlers.log.postMessage({n: 1});")
        #expect(context.evaluateScript("posted.length").toInt32() == 1)
        #expect(context.evaluateScript("timers").toInt32() == 0)
    }

    @Test func aPostBeforeTheRelayLeavesOnTheRelaysReadyEvent() throws {
        let context = try context(withDocument: true)
        let event = "cmux-test-post"
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: ["log"], channelEvent: event))
        context.evaluateScript("webkit.messageHandlers.log.postMessage({n: 1});")
        #expect(context.evaluateScript("posted.length").toInt32() == 0)
        // The relay's world comes up: it listens, then announces itself.
        context.evaluateScript("""
        document.addEventListener('\(event)', function (e) { posted.push(e.detail); e.preventDefault(); });
        document.dispatchEvent({ type: '\(ChromiumPageHostBridge.readyEvent(for: event))', defaultPrevented: false });
        """)
        #expect(exception == nil)
        #expect(context.evaluateScript("posted.length").toInt32() == 1, "the waiting post did not leave on the relay's ready event")
        #expect(context.evaluateScript("timers").toInt32() == 0, "the page polled a timer while it waited")
    }
}
