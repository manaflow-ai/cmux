@testable import CmuxNextPages
import JavaScriptCore
import Testing

struct PageChromiumZoomScriptTests {
    private func makeContext(withHTML: Bool = true) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var values = {}, listeners = {}, changes = 0, observers = [];
        var html = { style: {
          setProperty: (key, value) => values[key] = String(value),
          getPropertyValue: key => values[key] || ''
        } };
        var document = { documentElement: \(withHTML ? "html" : "null") };
        var window = {
          devicePixelRatio: 2,
          addEventListener: (name, callback) => (listeners[name] ||= []).push(callback),
          dispatchEvent: event => { if (event.type === 'cmux-ui-scale-change') changes++; }
        };
        window.top = window;
        function Event(name) { this.type = name; }
        function resize(ratio) { window.devicePixelRatio = ratio; listeners.resize.forEach(callback => callback()); }
        function MutationObserver(callback) { this.callback = callback; this.disconnected = false; observers.push(this); }
        MutationObserver.prototype.observe = function () {};
        MutationObserver.prototype.disconnect = function () { this.disconnected = true; };
        function insertHTML() {
          document.documentElement = html;
          observers.filter(observer => !observer.disconnected).forEach(observer => observer.callback());
        }
        """)
        return context
    }

    @Test func eachRendererResizePublishesItsZoomBeforeTheNextHostPush() throws {
        let context = try makeContext()
        context.evaluateScript(PageChromiumDocumentScripts.pageZoomScript(backingScale: 2))
        for (ratio, expected) in [(2.2, "1.1"), (3.0, "1.5"), (1.6, "0.8"), (2.0, "1")] {
            context.evaluateScript("resize(\(ratio))")
            #expect(context.exception == nil)
            #expect(context.evaluateScript("values['--cmux-ui-scale']").toString() == expected)
        }
        #expect(context.evaluateScript("changes").toInt32() == 5)
        context.evaluateScript("resize(2)")
        #expect(context.evaluateScript("changes").toInt32() == 5, "unchanged geometry needs no notification")
    }

    @Test func movingToAnotherDisplayKeepsZoomAndOnlyOneResizeListener() throws {
        let context = try makeContext()
        context.evaluateScript("window.devicePixelRatio = 3")
        context.evaluateScript(PageChromiumDocumentScripts.pageZoomScript(backingScale: 2))
        context.evaluateScript("window.devicePixelRatio = 1.5")
        context.evaluateScript(PageChromiumDocumentScripts.pageZoomScript(backingScale: 1))
        #expect(context.evaluateScript("values['--cmux-ui-scale']").toString() == "1.5")
        #expect(context.evaluateScript("listeners.resize.length").toInt32() == 1)
        context.evaluateScript("resize(1.1)")
        #expect(context.evaluateScript("values['--cmux-ui-scale']").toString() == "1.1")
    }

    @Test func aNewDocumentWaitsForHTMLAndStopsObservingAfterItArrives() throws {
        let context = try makeContext(withHTML: false)
        context.evaluateScript(PageChromiumDocumentScripts.pageZoomScript(backingScale: 2))
        #expect(context.exception == nil)
        context.evaluateScript("insertHTML()")
        #expect(context.evaluateScript("values['--cmux-ui-scale']").toString() == "1")
        #expect(context.evaluateScript("observers.every(observer => observer.disconnected)").toBool())
        context.evaluateScript("resize(2.4)")
        #expect(context.evaluateScript("values['--cmux-ui-scale']").toString() == "1.2")
    }
}
