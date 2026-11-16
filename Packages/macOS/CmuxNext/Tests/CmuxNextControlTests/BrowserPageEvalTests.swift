import AppKit
@testable import CmuxNextControl
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing
import WebKit

/// Promise values take the async engine path; a rejection or a failed conversion must never
/// escape as a parse failure and run the person's script a second time.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct BrowserPageEvalTests {
    @Test func evaluationUsesTheAsyncEngineAndPreservesStatementFallback() async throws {
        let (router, engine) = BrowserPageWaitTests().install { operation, index in
            if index == 0 {
                guard case .evaluateAsync = operation else {
                    Issue.record("page evaluation did not use the async engine")
                    return ["value": .null]
                }
                throw ControlError(code: "js_error", message: "SyntaxError: unexpected statement")
            }
            return ["value": 7]
        }
        let script = "var value = 7; value"
        let deadline = try #require(router.method(named: "browser.page.eval")?.fixedLimit)
        #expect(deadline > .milliseconds(BrowserPageScripts.promiseTimeoutMs), "the control router must let the page's timeout answer")
        #expect(router.method(named: "browser.page.state")?.fixedLimit == nil)
        let result = try await router.handle(ControlRequest(method: "browser.page.eval",
            params: ["tab": "tab_0123abcd", "script": .string(script)])).get()
        #expect(result["value"] == 7)
        #expect(engine.operations.count == 2)
        #expect(engine.operations.last == .evaluate(script))
    }

    @Test func aReportedSyntaxErrorNeverRepeatsTheScript() async {
        let (router, engine) = BrowserPageWaitTests().install { _, _ in
            ["value": ["__cmuxEvalError": "SyntaxError: conversion failed"]]
        }
        let result = await router.handle(ControlRequest(method: "browser.page.eval",
            params: ["tab": "tab_0123abcd", "script": "Promise.resolve(value)"]))
        #expect(result.failure?.code == "js_error")
        #expect(engine.operations.count == 1)
    }

    @Test func resolvedValuesRejectionsAndConversionFailuresAreReturnedByValue() async throws {
        let page = BrowserPageSnapshotTests.Page()
        await page.load()
        defer { page.window.closeAfterTest() }
        func evaluate(_ script: String) async throws -> JSONValue {
            let result = try await page.webView.callAsyncJavaScript(
                "return \(BrowserPageScripts.jsonSafe(script));", arguments: [:], in: nil, contentWorld: .page)
            return JSONValue(foundation: result ?? NSNull()) ?? .null
        }
        // Settle after the wrapper observes the pending promise, without a wall-clock delay.
        #expect(try await evaluate("new Promise(resolve => queueMicrotask(() => resolve({answer: 42})))") == ["answer": 42])
        #expect(try await evaluate("Promise.reject(new Error('rejected'))")["__cmuxEvalError"] == "Error: rejected")
        let badConversion = "(() => { window.evalCount = (window.evalCount || 0) + 1; return Promise.resolve({toJSON() { throw new SyntaxError('conversion'); }}); })()"
        #expect(try await evaluate(badConversion)["__cmuxEvalError"] == "SyntaxError: conversion")
        #expect(try await page.read("window.evalCount") == 1)
    }

    @Test func anUnsettledPromiseAnswersItsBoundedError() async throws {
        let page = BrowserPageSnapshotTests.Page()
        await page.load()
        defer { page.window.closeAfterTest() }
        let result = try await page.webView.callAsyncJavaScript(
            "return \(BrowserPageScripts.jsonSafe("new Promise(() => {})"));", arguments: [:], in: nil, contentWorld: .page)
        let value = JSONValue(foundation: result ?? NSNull())
        #expect(value?["__cmuxEvalError"] == "Error: the promise did not settle in 20 s")
    }
}
