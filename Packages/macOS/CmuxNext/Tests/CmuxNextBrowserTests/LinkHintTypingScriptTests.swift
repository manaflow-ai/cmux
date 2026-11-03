import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// `LinkHintSession.typingScript`, run for real in JavaScriptCore against a
/// small fake DOM: a bare `f` Chromium reports unhandled starts link hints
/// only when the page's focus is not typing. Gmail's compose body (a
/// contenteditable Chromium's `focus_on_editable_field` missed) started
/// hints, flashed yellow labels and took the letters typed after it
/// (https://github.com/manaflow-ai/cmux/issues/32982).
@Suite struct LinkHintTypingScriptTests {
    static let dom = """
    function el(tag, props) {
      var e = { tagName: tag, isContentEditable: false, disabled: false, readOnly: false };
      for (var k in props) e[k] = props[k];
      return e;
    }
    function doc(active) {
      var d = { designMode: 'off', body: el('BODY'), documentElement: el('HTML') };
      d.activeElement = active === undefined ? d.body : active;
      return d;
    }
    var document = doc();
    """

    static func typing(_ setup: String) throws -> Bool {
        let context = try #require(JSContext())
        context.evaluateScript(dom)
        context.evaluateScript(setup)
        let value = try #require(context.evaluateScript(LinkHintSession.typingScript))
        #expect(context.exception == nil)
        return value.toBool()
    }

    @Test func aContentEditableEditorIsTyping() throws {
        // Gmail's compose body: a div with contenteditable.
        #expect(try Self.typing("document.activeElement = el('DIV', { isContentEditable: true });"))
    }

    @Test func textFieldsAreTyping() throws {
        #expect(try Self.typing("document.activeElement = el('INPUT', { type: 'email' });"))
        #expect(try Self.typing("document.activeElement = el('TEXTAREA');"))
    }

    @Test func aDesignModeDocumentIsTyping() throws {
        #expect(try Self.typing("document.designMode = 'on';"))
    }

    @Test func anEditableBodyIsTyping() throws {
        // TinyMCE and CKEditor 4 type in the editable body of their iframe.
        #expect(try Self.typing("document.body.isContentEditable = true;"))
        #expect(try Self.typing("""
        var frame = doc(); frame.body.isContentEditable = true; frame.activeElement = frame.body;
        document.activeElement = el('IFRAME', { contentDocument: frame });
        """))
    }

    @Test func anEditorInsideAnOpenShadowRootIsTyping() throws {
        #expect(try Self.typing("""
        var inner = el('DIV', { isContentEditable: true });
        document.activeElement = el('RICH-EDITOR', { shadowRoot: { activeElement: inner } });
        """))
    }

    @Test func anEditorInASameOriginFrameIsTyping() throws {
        #expect(try Self.typing("""
        document.activeElement = el('IFRAME', { contentDocument: doc(el('DIV', { isContentEditable: true })) });
        """))
    }

    @Test func aCrossOriginFrameMayBeTyping() throws {
        // Its document is not readable: the key may be typing in it.
        #expect(try Self.typing("document.activeElement = el('IFRAME', { contentDocument: null });"))
    }

    @Test func aPageWithNoFocusedFieldIsNotTyping() throws {
        #expect(try !Self.typing(""))
        #expect(try !Self.typing("document.activeElement = el('A', { href: 'https://example.com' });"))
        #expect(try !Self.typing("document.activeElement = el('INPUT', { type: 'checkbox' });"))
        #expect(try !Self.typing("document.activeElement = el('INPUT', { type: 'text', readOnly: true });"))
        #expect(try !Self.typing("document.activeElement = el('IFRAME', { contentDocument: doc() });"))
    }
}
