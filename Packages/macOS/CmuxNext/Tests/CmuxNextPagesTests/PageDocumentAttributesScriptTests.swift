@testable import CmuxNextPages
import JavaScriptCore
import Testing

/// ``PageWebView/attributesScript(_:)`` runs at document start in both engines. Chromium runs it
/// before `<html>` exists (`document.documentElement` is null), where it used to throw, so a
/// Chromium page, the agent chat by default, got no `data-*` attributes and `data-needs-you="off"`
/// never hid Needs you (cmux#24071). These run the script against a stand-in document.
struct PageDocumentAttributesScriptTests {
    /// A document whose `<html>` the test inserts (`insertHTML()`), with a MutationObserver that
    /// the insertion notifies, as the HTML parser does.
    private func makeContext(withHTML: Bool) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var observers = [];
        var html = { attrs: {}, setAttribute: function (name, value) { this.attrs[name] = value; } };
        var document = { documentElement: \(withHTML ? "html" : "null") };
        function MutationObserver(callback) { this.callback = callback; this.disconnected = false; observers.push(this); }
        MutationObserver.prototype.observe = function (target) { this.target = target; };
        MutationObserver.prototype.disconnect = function () { this.disconnected = true; };
        function insertHTML() {
          document.documentElement = html;
          observers.forEach(function (o) { if (!o.disconnected && o.target === document) o.callback([], o); });
        }
        """)
        return context
    }

    @Test func attributesWaitForTheHTMLElementWhenTheScriptRunsBeforeIt() throws {
        let script = try #require(PageWebView.attributesScript(["needs-you": "off", "scrollers": "overlay"]))
        let context = try makeContext(withHTML: false)
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("Object.keys(html.attrs).length").toInt32() == 0)
        context.evaluateScript("insertHTML()")
        #expect(context.evaluateScript("html.attrs['data-needs-you']").toString() == "off")
        #expect(context.evaluateScript("html.attrs['data-scrollers']").toString() == "overlay")
        #expect(context.evaluateScript("observers.every(function (o) { return o.disconnected; })").toBool())
    }

    @Test func attributesAreSetAtOnceWhenTheHTMLElementExists() throws {
        let script = try #require(PageWebView.attributesScript(["needs-you": "off"]))
        let context = try makeContext(withHTML: true)
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("html.attrs['data-needs-you']").toString() == "off")
        #expect(context.evaluateScript("observers.length").toInt32() == 0)
    }

    @Test func noAttributesMeansNoScript() {
        #expect(PageWebView.attributesScript([:]) == nil)
        #expect(PageWebView.attributesScript(["Bad Name": "x"]) == nil)
    }
}
