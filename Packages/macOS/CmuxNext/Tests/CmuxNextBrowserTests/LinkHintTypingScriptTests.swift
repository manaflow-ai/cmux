import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// `LinkHintSession.focusScript`, run for real in JavaScriptCore against a
/// small fake DOM: a link hint session draws labels only when the page says no
/// text field has the keyboard. Chromium's own editable-focus flag can miss
/// Gmail's compose body, so this answer is what keeps yellow labels off the
/// page while typing (https://github.com/manaflow-ai/cmux/issues/32982).
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

    static func editing(_ setup: String) throws -> Bool {
        let context = try #require(JSContext())
        context.evaluateScript(dom)
        context.evaluateScript(setup)
        let answer = try #require(context.evaluateScript(LinkHintSession.focusScript)?.toString())
        #expect(context.exception == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Bool])
        return try #require(object["editing"])
    }

    @Test func aContentEditableEditorIsEditing() throws {
        // Gmail's compose body: a div with contenteditable.
        #expect(try Self.editing("document.activeElement = el('DIV', { isContentEditable: true });"))
    }

    @Test func textFieldsAreEditing() throws {
        #expect(try Self.editing("document.activeElement = el('INPUT', { type: 'email' });"))
        #expect(try Self.editing("document.activeElement = el('TEXTAREA');"))
    }

    @Test func aDesignModeDocumentIsEditing() throws {
        #expect(try Self.editing("document.designMode = 'on';"))
    }

    @Test func anEditableBodyIsEditing() throws {
        // TinyMCE and CKEditor 4 type in the editable body of their iframe.
        #expect(try Self.editing("document.body.isContentEditable = true;"))
        #expect(try Self.editing("""
        var frame = doc(); frame.body.isContentEditable = true; frame.activeElement = frame.body;
        document.activeElement = el('IFRAME', { contentDocument: frame });
        """))
    }

    @Test func anEditorInsideAnOpenShadowRootIsEditing() throws {
        #expect(try Self.editing("""
        var inner = el('DIV', { isContentEditable: true });
        document.activeElement = el('RICH-EDITOR', { shadowRoot: { activeElement: inner } });
        """))
    }

    @Test func anEditorInASameOriginFrameIsEditing() throws {
        #expect(try Self.editing("""
        document.activeElement = el('IFRAME', { contentDocument: doc(el('DIV', { isContentEditable: true })) });
        """))
    }

    @Test func aCrossOriginFrameMayBeEditing() throws {
        // Its document is not readable: the key may be typing in it.
        #expect(try Self.editing("document.activeElement = el('IFRAME', { contentDocument: null });"))
    }

    @Test func aPageWithNoFocusedFieldIsNotEditing() throws {
        #expect(try !Self.editing(""))
        #expect(try !Self.editing("document.activeElement = el('A', { href: 'https://example.com' });"))
        #expect(try !Self.editing("document.activeElement = el('INPUT', { type: 'checkbox' });"))
        #expect(try !Self.editing("document.activeElement = el('IFRAME', { contentDocument: doc() });"))
    }
}
