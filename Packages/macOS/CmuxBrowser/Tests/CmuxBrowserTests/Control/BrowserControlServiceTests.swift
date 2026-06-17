import Foundation
import Testing
@testable import CmuxBrowser

private final class FakeUndefined {}

@Suite("BrowserControlService")
struct BrowserControlServiceTests {
    let service = BrowserControlService()

    @Test("jsonLiteral encodes strings with escaping and strips array brackets")
    func jsonLiteralString() {
        #expect(service.jsonLiteral("hi") == "\"hi\"")
        #expect(service.jsonLiteral("a\"b") == "\"a\\\"b\"")
        #expect(service.jsonLiteral(42) == "42")
        #expect(service.jsonLiteral(true) == "true")
    }

    @Test("normalizeJSValue maps undefined sentinel to the eval envelope")
    func normalizeUndefined() {
        let sentinel = FakeUndefined()
        let result = service.normalizeJSValue(sentinel) { $0 is FakeUndefined }
        let dict = try? #require(result as? [String: Any])
        #expect(dict?["__cmux_t"] as? String == "undefined")
        #expect(dict?["__cmux_v"] is NSNull)
    }

    @Test("normalizeJSValue passes through scalars, nil, and nested containers")
    func normalizePassthrough() {
        #expect(service.normalizeJSValue(nil) { _ in false } is NSNull)
        #expect(service.normalizeJSValue("x") { _ in false } as? String == "x")
        let nested = service.normalizeJSValue(["a": [1, 2]]) { _ in false } as? [String: Any]
        #expect((nested?["a"] as? [Any])?.count == 2)
    }

    @Test("normalizeJSValue honors a custom envelope")
    func normalizeCustomEnvelope() {
        let custom = BrowserControlService(
            evalEnvelope: BrowserEvalEnvelope(typeKey: "T", valueKey: "V", typeUndefined: "U", typeValue: "VAL")
        )
        let dict = custom.normalizeJSValue(FakeUndefined()) { $0 is FakeUndefined } as? [String: Any]
        #expect(dict?["T"] as? String == "U")
        #expect(dict?["V"] is NSNull)
    }

    @Test("failureLooksLikeCSPEvalBlock matches CSP phrasings")
    func cspDetection() {
        #expect(service.failureLooksLikeCSPEvalBlock("blocked: unsafe-eval"))
        #expect(service.failureLooksLikeCSPEvalBlock("Refused to evaluate a string"))
        #expect(service.failureLooksLikeCSPEvalBlock("violates the Content Security Policy"))
        #expect(service.failureLooksLikeCSPEvalBlock("blocked by CSP"))
        #expect(!service.failureLooksLikeCSPEvalBlock("ReferenceError: x is not defined"))
    }

    @Test("describeJavaScriptError prefers the WK exception message and line")
    func describeError() {
        let withLine = NSError(domain: "WK", code: 1, userInfo: [
            "WKJavaScriptExceptionMessage": "boom",
            "WKJavaScriptExceptionLineNumber": 7
        ])
        #expect(service.describeJavaScriptError(withLine) == "boom (line 7)")

        let noLine = NSError(domain: "WK", code: 1, userInfo: [
            "WKJavaScriptExceptionMessage": "boom"
        ])
        #expect(service.describeJavaScriptError(noLine) == "boom")

        let generic = NSError(domain: "WK", code: 1, userInfo: [NSLocalizedDescriptionKey: "fallback"])
        #expect(service.describeJavaScriptError(generic) == "fallback")
    }

    @Test("elementNotFoundMessage chooses the branch by counts")
    func notFoundMessages() {
        #expect(service.elementNotFoundMessage(selector: "#x", matchCount: 2, visibleCount: 0)
            == "Element \"#x\" is present but not visible.")
        #expect(service.elementNotFoundMessage(selector: "#x", matchCount: 3, visibleCount: 2)
            == "Selector \"#x\" matched multiple elements.")
        #expect(service.elementNotFoundMessage(selector: "#x", matchCount: 0, visibleCount: 0)
            == "Element \"#x\" not found or not visible. Run 'browser snapshot' to see current page elements.")
    }

    @Test("script builders interpolate literals and stay self-invoking")
    func scriptBuilders() {
        let diag = service.notFoundDiagnosticsScript(selector: "#x")
        #expect(diag.contains("const __selector = \"#x\""))
        #expect(diag.hasPrefix("(() => {"))

        let role = service.findRoleFinderBody(role: "button", name: "save", exact: true)
        #expect(role.contains("const __targetRole = String(\"button\").toLowerCase();"))
        #expect(role.contains("const __targetName = \"save\";"))
        #expect(role.contains("const __exact = true;"))

        let roleNoName = service.findRoleFinderBody(role: "link", name: nil, exact: false)
        #expect(roleNoName.contains("const __targetName = null;"))
        #expect(roleNoName.contains("const __exact = false;"))

        let wrapped = service.findScript(finderBody: role)
        #expect(wrapped.contains("const __cmuxFound = (() => {"))
        #expect(wrapped.contains("const __targetRole"))

        let nth = service.findNthScript(selector: ".row", index: -1)
        #expect(nth.contains("let idx = -1;"))
        #expect(nth.contains("document.querySelectorAll(\".row\")"))
    }
}
