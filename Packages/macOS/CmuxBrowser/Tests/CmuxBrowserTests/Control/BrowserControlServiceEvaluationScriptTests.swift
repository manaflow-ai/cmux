import Foundation
import JavaScriptCore
import Testing
@testable import CmuxBrowser

@Suite("BrowserControlService evaluation script")
struct BrowserControlServiceEvaluationScriptTests {
    private let service = BrowserControlService()

    @Test("repeated aliases become independent JSON-safe values")
    func repeatedAliasesAreJSONSafe() throws {
        let envelope = try evaluate(
            """
            (() => {
              const shared = {answer: 42};
              return {first: shared, second: shared, items: [shared, shared]};
            })()
            """
        )

        let value = try #require(envelope[service.evalEnvelope.valueKey] as? [String: Any])
        let first = try #require(value["first"] as? [String: Any])
        let second = try #require(value["second"] as? [String: Any])
        let items = try #require(value["items"] as? [[String: Any]])
        #expect(envelope[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeValue)
        #expect(first["answer"] as? Int == 42)
        #expect(second["answer"] as? Int == 42)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0["answer"] as? Int == 42 })
    }

    @Test("true cycles produce a deterministic error envelope")
    func cycleProducesExplicitError() throws {
        let envelope = try evaluate(
            """
            (() => {
              const value = {};
              value.self = value;
              return value;
            })()
            """
        )

        #expect(envelope[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeError)
        #expect(
            envelope[service.evalEnvelope.errorCodeKey] as? String
                == service.evalEnvelope.circularReferenceCode
        )
        #expect(
            envelope[service.evalEnvelope.errorMessageKey] as? String
                == service.evalEnvelope.circularReferenceMessage
        )

        switch service.resolveEvaluationEnvelope(envelope) {
        case .error(let code, let message):
            #expect(code == "circular_reference")
            #expect(message == "browser.eval result contains a circular reference")
        default:
            Issue.record("Expected an explicit browser-eval error resolution")
        }
    }

    @Test("DOMRect-branded values are flattened before bridging")
    func domRectIsFlattened() throws {
        let envelope = try evaluate(
            """
            (() => {
              const rect = {};
              const fields = {x: 1, y: 2, width: 30, height: 40, top: 2, right: 31, bottom: 42, left: 1};
              for (const [key, value] of Object.entries(fields)) {
                Object.defineProperty(rect, key, {value, enumerable: false});
              }
              Object.defineProperty(rect, Symbol.toStringTag, {value: 'DOMRect'});
              return rect;
            })()
            """
        )

        let value = try #require(envelope[service.evalEnvelope.valueKey] as? [String: Any])
        #expect(value["width"] as? Int == 30)
        #expect(value["height"] as? Int == 40)
        #expect(value["right"] as? Int == 31)
        #expect(value["bottom"] as? Int == 42)
    }

    private func evaluate(_ script: String) throws -> [String: Any] {
        let context = try #require(JSContext())
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }
        context.evaluateScript("var document = {};")

        let body = service.evaluationScript(
            script: script,
            useEval: true,
            frameSelector: nil
        )
        let promise = try #require(context.evaluateScript("(async () => {\n\(body)\n})()"))
        var resolved: JSValue?
        var rejectionMessage: String?
        let fulfilled: @convention(block) (JSValue) -> Void = { value in
            resolved = value
        }
        let rejected: @convention(block) (JSValue) -> Void = { value in
            rejectionMessage = value.toString()
        }
        promise.invokeMethod("then", withArguments: [fulfilled, rejected])

        #expect(exceptionMessage == nil)
        #expect(rejectionMessage == nil)
        let result = try #require(resolved)
        context.setObject(result, forKeyedSubscript: "__cmuxTestResult" as NSString)
        let json = try #require(context.evaluateScript("JSON.stringify(__cmuxTestResult)")?.toString())
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
