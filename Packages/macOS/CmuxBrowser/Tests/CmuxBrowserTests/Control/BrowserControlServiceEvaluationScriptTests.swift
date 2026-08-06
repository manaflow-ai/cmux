import Foundation
import JavaScriptCore
import Testing
import WebKit
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
            #expect(message == service.evalEnvelope.circularReferenceMessage)
        default:
            Issue.record("Expected an explicit browser-eval error resolution")
        }
    }

    @Test("shared alias expansion is rejected before exponential growth")
    func sharedAliasExpansionProducesExplicitError() throws {
        let envelope = try evaluate(
            """
            (() => {
              var value = {answer: 42};
              for (let depth = 0; depth < 14; depth += 1) {
                value = {left: value, right: value};
              }
              return value;
            })()
            """
        )

        #expect(envelope[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeError)
        #expect(envelope[service.evalEnvelope.errorCodeKey] as? String == "result_too_complex")

        switch service.resolveEvaluationEnvelope(envelope) {
        case .error(let code, let message):
            #expect(code == "result_too_complex")
            #expect(!message.isEmpty)
        default:
            Issue.record("Expected a bounded browser-eval error resolution")
        }
    }

    @Test("an unavailable selected frame never falls back to the top document")
    func unavailableFrameProducesExplicitError() throws {
        let documentSetups = [
            "var document = {secret: 'top-secret', querySelector: () => null};",
            "var document = {secret: 'top-secret', querySelector: () => ({})};",
            """
            var document = {
              secret: 'top-secret',
              querySelector: () => ({
                get contentDocument() { throw new Error('cross-origin'); }
              })
            };
            """,
        ]

        for documentSetup in documentSetups {
            let envelope = try evaluate(
                "document.secret",
                frameSelector: "#selected-frame",
                documentSetup: documentSetup
            )
            #expect(envelope[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeError)
            #expect(envelope[service.evalEnvelope.errorCodeKey] as? String == "frame_unavailable")
        }
    }

    @Test("result budget rejects before reading a property beyond the node cap")
    func nodeBudgetStopsBeforeOverflowGetter() throws {
        let envelope = try evaluate(
            """
            (() => {
              const value = {};
              for (let index = 0; index < 9999; index += 1) {
                value[`p${index}`] = index;
              }
              Object.defineProperty(value, 'overflow', {
                enumerable: true,
                get() { throw new Error('overflow getter must not run'); }
              });
              return value;
            })()
            """
        )

        #expect(envelope[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeError)
        #expect(envelope[service.evalEnvelope.errorCodeKey] as? String == "result_too_complex")
    }

    @Test("aggregate string and key payloads are bounded")
    func oversizedTextProducesExplicitError() throws {
        let oversizedString = try evaluate("'x'.repeat(1000001)")
        #expect(oversizedString[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeError)
        #expect(oversizedString[service.evalEnvelope.errorCodeKey] as? String == "result_too_complex")

        let oversizedKey = try evaluate("({['k'.repeat(1000001)]: 1})")
        #expect(oversizedKey[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeError)
        #expect(oversizedKey[service.evalEnvelope.errorCodeKey] as? String == "result_too_complex")

        let aggregateStrings = try evaluate(
            "({first: 'a'.repeat(400000), second: 'b'.repeat(400000), third: 'c'.repeat(400000)})"
        )
        #expect(aggregateStrings[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeError)
        #expect(aggregateStrings[service.evalEnvelope.errorCodeKey] as? String == "result_too_complex")
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

    @MainActor
    @Test("top-level undefined omits the value property before WebKit bridging")
    func topLevelUndefinedEnvelopeOmitsValueProperty() throws {
        let (context, envelope) = try evaluateRaw("undefined")
        context.setObject(envelope, forKeyedSubscript: "__cmuxTestResult" as NSString)
        context.setObject(
            service.evalEnvelope.valueKey,
            forKeyedSubscript: "__cmuxTestValueKey" as NSString
        )

        let hasValueProperty = context.evaluateScript(
            "Object.prototype.hasOwnProperty.call(__cmuxTestResult, __cmuxTestValueKey)"
        )
        #expect(hasValueProperty?.toBool() == false)
    }

    @MainActor
    @Test("top-level undefined crosses the real WebKit result bridge without a value")
    func topLevelUndefinedIsBridgeSafe() async throws {
        let webView = WKWebView()
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserEvaluationScriptNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString("<!doctype html><title>bridge test</title>", baseURL: nil)
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

        let body = service.evaluationScript(
            script: "undefined",
            useEval: true,
            frameSelector: nil
        )
        let rawValue = try await webView.callAsyncJavaScript(
            body,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let envelope = try #require(rawValue as? [String: Any])

        #expect(envelope[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeUndefined)
        #expect(envelope[service.evalEnvelope.valueKey] == nil)
        switch service.resolveEvaluationEnvelope(envelope) {
        case .undefined:
            break
        default:
            Issue.record("Expected a top-level undefined browser-eval resolution")
        }
        _ = navigationDelegate
    }

    @MainActor
    @Test("nested undefined values cross the real WebKit result bridge as null")
    func nestedUndefinedValuesAreBridgeSafe() async throws {
        let webView = WKWebView()
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserEvaluationScriptNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString("<!doctype html><title>bridge test</title>", baseURL: nil)
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

        let body = service.evaluationScript(
            script: "({objectValue: undefined, items: [1, undefined, , 4]})",
            useEval: true,
            frameSelector: nil
        )
        let rawValue = try await webView.callAsyncJavaScript(
            body,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let envelope = try #require(rawValue as? [String: Any])
        let value = try #require(envelope[service.evalEnvelope.valueKey] as? [String: Any])
        let items = try #require(value["items"] as? [Any])

        #expect(envelope[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeValue)
        #expect(value["objectValue"] is NSNull)
        #expect(items.count == 4)
        #expect(items[1] is NSNull)
        #expect(items[2] is NSNull)
        _ = navigationDelegate
    }

    @MainActor
    @Test("a selected frame owns the complete JavaScript global realm")
    func selectedFrameOwnsCompleteGlobalRealm() async throws {
        let webView = WKWebView()
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserEvaluationScriptNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString("<!doctype html><title>top-title</title>", baseURL: nil)
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

        _ = try await webView.callAsyncJavaScript(
            """
            window.__cmuxRealmMarker = 'top';
            window.__cmuxFrameOnly = 'top-global';
            const frame = document.createElement('iframe');
            frame.id = 'selected-frame';
            document.body.appendChild(frame);
            frame.contentDocument.title = 'frame-title';
            frame.contentWindow.__cmuxRealmMarker = 'frame';
            frame.contentWindow.__cmuxFrameOnly = 'frame-global';
            frame.contentWindow.location.hash = 'frame';
            return true;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        let body = service.evaluationScript(
            script: "({marker: window.__cmuxRealmMarker, frameOnly: __cmuxFrameOnly, href: location.href, title: document.title})",
            useEval: true,
            frameSelector: "#selected-frame"
        )
        let rawValue = try await webView.callAsyncJavaScript(
            body,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let envelope = try #require(rawValue as? [String: Any])
        let value = try #require(envelope[service.evalEnvelope.valueKey] as? [String: Any])

        #expect(value["marker"] as? String == "frame")
        #expect(value["frameOnly"] as? String == "frame-global")
        #expect((value["href"] as? String)?.hasSuffix("#frame") == true)
        #expect(value["title"] as? String == "frame-title")
        _ = navigationDelegate
    }

    @Test("custom prototypes are copied without invoking serialization hooks")
    func customPrototypeIsCopiedAsPlainObject() throws {
        let envelope = try evaluate(
            """
            (() => {
              function Payload() {
                this.answer = 42;
              }
              Payload.prototype.toJSON = function() { return 'prototype-hook'; };
              return new Payload();
            })()
            """
        )

        let value = try #require(envelope[service.evalEnvelope.valueKey] as? [String: Any])
        #expect(value["answer"] as? Int == 42)
    }

    @Test("Date and BigInt values have stable JSON-safe representations")
    func nonJSONBuiltinsAreNormalized() throws {
        let envelope = try evaluate(
            """
            ({date: new Date('2026-01-02T03:04:05Z'), integer: 9007199254740993n})
            """
        )

        let value = try #require(envelope[service.evalEnvelope.valueKey] as? [String: Any])
        #expect((value["date"] as? [String: Any])?.isEmpty == true)
        #expect(value["integer"] as? String == "9007199254740993")
    }

    @Test("cycles on exotic prototypes produce the stable error envelope")
    func exoticPrototypeCycleProducesExplicitError() throws {
        let envelope = try evaluate(
            """
            (() => {
              const value = new Map();
              Object.defineProperty(value, 'self', {value, enumerable: true});
              return value;
            })()
            """
        )

        #expect(envelope[service.evalEnvelope.typeKey] as? String == service.evalEnvelope.typeError)
        #expect(
            envelope[service.evalEnvelope.errorCodeKey] as? String
                == service.evalEnvelope.circularReferenceCode
        )
    }

    @Test("an own proto property remains ordinary serialized data")
    func ownProtoPropertyIsPreserved() throws {
        let envelope = try evaluate(
            """
            (() => {
              const value = Object.create(null);
              Object.defineProperty(value, '__proto__', {
                value: 'ordinary-value',
                enumerable: true
              });
              return value;
            })()
            """
        )

        let value = try #require(envelope[service.evalEnvelope.valueKey] as? [String: Any])
        #expect(value["__proto__"] as? String == "ordinary-value")
    }

    private func evaluate(
        _ script: String,
        frameSelector: String? = nil,
        documentSetup: String = "var document = {};"
    ) throws -> [String: Any] {
        let (context, result) = try evaluateRaw(
            script,
            frameSelector: frameSelector,
            documentSetup: documentSetup
        )
        context.setObject(result, forKeyedSubscript: "__cmuxTestResult" as NSString)
        let json = try #require(context.evaluateScript("JSON.stringify(__cmuxTestResult)")?.toString())
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func evaluateRaw(
        _ script: String,
        frameSelector: String? = nil,
        documentSetup: String = "var document = {};"
    ) throws -> (JSContext, JSValue) {
        let context = try #require(JSContext())
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }
        context.evaluateScript(documentSetup)

        let body = service.evaluationScript(
            script: script,
            useEval: true,
            frameSelector: frameSelector
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
        return (context, result)
    }
}
