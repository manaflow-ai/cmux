@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// Where the code suggestion goes (DESIGN.md "Delivery"): the anchor script finds the code field
/// (a row of boxes, the one-time-code field) in the top frame and reports only its geometry as
/// viewport fractions; the card's code reads in two groups.
@Suite struct VerificationFieldAnchorTests {
    static let dom = """
    var window = { innerWidth: 1000, innerHeight: 800 }; window.top = window;
    function HTMLInputElement() {}
    function field(attrs, rect) {
      var el = Object.create(HTMLInputElement.prototype);
      el.type = attrs.type || 'text'; el.maxLength = attrs.maxLength || -1; el.autocomplete = attrs.autocomplete || '';
      el.disabled = false; el.readOnly = false; el.offsetParent = {}; el.value = '';
      el.getBoundingClientRect = function () { return { left: rect[0], top: rect[1], right: rect[0] + rect[2], bottom: rect[1] + rect[3], width: rect[2], height: rect[3] }; };
      return el;
    }
    var document = { activeElement: null, inputs: [],
      querySelectorAll: function (s) { return s === 'input' ? document.inputs : []; },
      querySelector: function (s) { return s.indexOf('one-time-code') < 0 ? null : (document.inputs.filter(function (el) { return el.autocomplete === 'one-time-code'; })[0] || null); } };
    """

    static func anchor(_ setup: String) throws -> VerificationFieldAnchor? {
        let context = try #require(JSContext())
        context.evaluateScript(dom)
        context.evaluateScript("var innerWidth = window.innerWidth, innerHeight = window.innerHeight;")
        context.evaluateScript(setup)
        let result = context.evaluateScript(VerificationPageScripts.anchorScript)
        let value: BrowserJSValue = result?.isString == true ? .string(result?.toString() ?? "") : .null
        return VerificationFieldAnchor(scriptResult: value)
    }

    /// Slack's six boxes: the anchor spans the first box to the last.
    @Test func aRowOfBoxesIsAnchoredFirstToLast() throws {
        let anchor = try #require(try Self.anchor("document.inputs = [0,1,2,3,4,5].map(function (i) { return field({maxLength: 1}, [300 + i * 60, 400, 50, 60]); });"))
        #expect(anchor.rect == CGRect(x: 0.3, y: 0.5, width: 0.35, height: 0.075))
        #expect(anchor.rect(in: CGSize(width: 500, height: 400)) == CGRect(x: 150, y: 200, width: 175, height: 30))
    }

    @Test func theOneTimeCodeFieldIsAnchored() throws {
        let anchor = try #require(try Self.anchor("document.inputs = [field({type: 'email'}, [0, 0, 100, 20]), field({autocomplete: 'one-time-code'}, [100, 200, 300, 40])];"))
        #expect(anchor.rect == CGRect(x: 0.1, y: 0.25, width: 0.3, height: 0.05))
    }

    @Test func noFieldOrASubframeHasNoAnchor() throws {
        #expect(try Self.anchor("document.inputs = [];") == nil)
        #expect(try Self.anchor("window.top = {}; document.inputs = [field({autocomplete: 'one-time-code'}, [100, 200, 300, 40])];") == nil)
    }

    @Test func aFieldScrolledOutOfViewHasNoAnchor() throws {
        #expect(try Self.anchor("document.inputs = [field({autocomplete: 'one-time-code'}, [100, -200, 300, 40])];") == nil)
    }

    @Test(arguments: [("482913", "482\u{2009}913"), ("Q7K2PL", "Q7K\u{2009}2PL"), ("12345678", "1234\u{2009}5678"), ("4829135", "4829135")])
    func theCodeReadsInTwoGroups(code: String, shown: String) {
        #expect(VerificationSuggestionPanel.grouped(code) == shown)
    }
}
