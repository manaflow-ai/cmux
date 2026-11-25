@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// The page scripts of email verification AutoFill, run for real in JavaScriptCore against a small
/// fake DOM (DESIGN.md "Page signal", "Delivery"): the detector reports only on an https top
/// frame that waits for a verification email, and only `{waiting: true}`; the fill script types
/// the code into the right field, splits it over one-character fields, and never submits.
@Suite struct VerificationPageScriptsTests {
    /// A fake DOM: `inputs` are the page's text fields, `text` its visible text.
    static let dom = """
    var posted = [], submitted = 0, timers = [];
    var setTimeout = function (f) { timers.push(f); return timers.length; };
    function runTimers() { for (var i = 0; i < 20 && timers.length; i++) { var t = timers; timers = []; t.forEach(function (f) { f(); }); } }
    function MutationObserver(cb) { this.cb = cb; }
    MutationObserver.prototype.observe = function () {};
    MutationObserver.prototype.disconnect = function () {};
    function Event(type) { this.type = type; }
    function HTMLInputElement() {}
    Object.defineProperty(HTMLInputElement.prototype, 'value', {
      get: function () { return this._v || ''; }, set: function (v) { this._v = String(v); }, configurable: true });
    function field(attrs) {
      var el = Object.create(HTMLInputElement.prototype);
      el.type = attrs.type || 'text'; el.maxLength = attrs.maxLength || -1; el.autocomplete = attrs.autocomplete || '';
      el.disabled = false; el.readOnly = false; el.offsetParent = {}; el.events = [];
      el.focus = function () { document.activeElement = el; };
      el.dispatchEvent = function (e) { el.events.push(e.type); };
      return el;
    }
    var window = {}; window.top = window;
    var location = { protocol: 'https:' };
    var document = {
      readyState: 'complete', documentElement: {}, activeElement: null, inputs: [], body: { innerText: '' },
      addEventListener: function () {}, removeEventListener: function () {},
      querySelectorAll: function (s) { return s === 'input' ? document.inputs : []; },
      querySelector: function (s) {
        if (s.indexOf('one-time-code') < 0) return null;
        return document.inputs.filter(function (el) { return el.autocomplete === 'one-time-code'; })[0] || null;
      },
    };
    """

    static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(dom)
        return context
    }

    static func detect(_ setup: String) throws -> [String] {
        let context = try context()
        context.evaluateScript(setup)
        context.evaluateScript(VerificationPageScripts.detectorScript(post: "posted.push(JSON.stringify(report))"))
        context.evaluateScript("runTimers()")
        return try #require(context.evaluateScript("posted").toArray() as? [String])
    }

    @Test func aPageThatSaysItSentACodeReportsOnce() throws {
        let posted = try Self.detect("document.body.innerText = 'We sent a verification code to you@example.com';")
        #expect(posted == [#"{"waiting":true}"#])
        #expect(VerificationPageScripts.isWaitingReport(posted[0]))
    }

    @Test func aOneTimeCodeFieldReports() throws {
        #expect(try Self.detect("document.inputs = [field({autocomplete: 'one-time-code'})];").count == 1)
    }

    /// Slack's and others' wording: "We emailed you a code", "We've emailed a code".
    @Test(arguments: [
        "We emailed you a code. Enter it below to sign in.",
        "We've emailed a 6-character code to you@example.com.",
        "Check your email for a code",
        "Enter the 6-digit code we sent to your email",
    ])
    func aPageThatSaysItEmailedACodeReports(text: String) throws {
        #expect(try Self.detect("document.body.innerText = \(String(reflecting: text));").count == 1)
    }

    /// A row of one-character boxes (Slack's 3-3, most 6-box code screens) is a code field even
    /// with no autocomplete hint and no recognized text.
    @Test func aRowOfOneCharacterBoxesReports() throws {
        #expect(try Self.detect("document.inputs = [0,1,2,3,4,5].map(function () { return field({maxLength: 1}); });").count == 1)
    }

    /// One or two one-character fields (a middle initial) are not a code.
    @Test func twoOneCharacterFieldsDoNotReport() throws {
        #expect(try Self.detect("document.inputs = [field({maxLength: 1}), field({maxLength: 1})];").isEmpty)
    }

    @Test func anOrdinaryPageDoesNotReport() throws {
        #expect(try Self.detect("document.body.innerText = 'Welcome to our store. Free shipping on orders over $50.';").isEmpty)
    }

    @Test func aSubframeDoesNotReport() throws {
        #expect(try Self.detect("window.top = {}; document.body.innerText = 'Check your email for a code';").isEmpty)
    }

    @Test func anInsecurePageDoesNotReport() throws {
        #expect(try Self.detect("location.protocol = 'http:'; document.body.innerText = 'Check your email';").isEmpty)
    }

    @Test func aReportIsOnlyTheWaitingFlag() {
        #expect(VerificationPageScripts.isWaitingReport(["waiting": true]))
        #expect(!VerificationPageScripts.isWaitingReport(["waiting": false]))
        #expect(!VerificationPageScripts.isWaitingReport("not json"))
    }

    // MARK: - Fill

    static func fill(_ setup: String, code: String = "482913") throws -> (filled: Bool, context: JSContext) {
        let context = try context()
        context.evaluateScript(setup)
        let result = context.evaluateScript(VerificationPageScripts.fillScript(code: code))
        return (result?.toBool() ?? false, context)
    }

    @Test func fillsTheOneTimeCodeField() throws {
        let (filled, context) = try Self.fill("document.inputs = [field({type: 'email'}), field({autocomplete: 'one-time-code'})];")
        #expect(filled)
        #expect(context.evaluateScript("document.inputs[1].value").toString() == "482913")
        #expect(context.evaluateScript("document.inputs[1].events.join(',')").toString() == "input,change")
        #expect(context.evaluateScript("submitted").toInt32() == 0)
    }

    @Test func fillsTheFocusedField() throws {
        let (filled, context) = try Self.fill("document.inputs = [field({}), field({})]; document.activeElement = document.inputs[1];")
        #expect(filled)
        #expect(context.evaluateScript("document.inputs[0].value").toString() == "")
        #expect(context.evaluateScript("document.inputs[1].value").toString() == "482913")
    }

    @Test func splitsTheCodeOverOneCharacterFields() throws {
        let (filled, context) = try Self.fill("document.inputs = [0,1,2,3,4,5].map(function () { return field({maxLength: 1}); });")
        #expect(filled)
        #expect(context.evaluateScript("document.inputs.map(function (el) { return el.value; }).join('')").toString() == "482913")
    }

    /// A dashed code (`Q7K-2PL`) reaches Slack's six boxes one character each.
    @Test func aDashedCodeFillsSixBoxes() throws {
        let (filled, context) = try Self.fill("document.inputs = [0,1,2,3,4,5].map(function () { return field({maxLength: 1}); });", code: "Q7K2PL")
        #expect(filled)
        #expect(context.evaluateScript("document.inputs.map(function (el) { return el.value; }).join('')").toString() == "Q7K2PL")
    }

    @Test func fillsNothingWhenNoFieldFits() throws {
        let (filled, _) = try Self.fill("document.inputs = [];")
        #expect(!filled)
    }

    @Test func fillsNothingInASubframe() throws {
        let (filled, _) = try Self.fill("window.top = {}; document.inputs = [field({autocomplete: 'one-time-code'})];")
        #expect(!filled)
    }

    /// The code reaches the page only as a string value, whatever it holds.
    @Test func aHostileCodeStaysAString() throws {
        let code = #"1"); submitted = 1; ("</script>"#
        let (_, context) = try Self.fill("document.inputs = [field({autocomplete: 'one-time-code'})];", code: code)
        #expect(context.evaluateScript("submitted").toInt32() == 0)
        #expect(context.evaluateScript("document.inputs[0].value").toString() == code)
    }
}
