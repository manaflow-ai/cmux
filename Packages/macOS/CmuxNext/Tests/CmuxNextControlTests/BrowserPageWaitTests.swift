@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// `browser.page.wait` blocks in the page until a selector, URL, text,
/// load state or expression holds (the old `cmux browser wait`), and starts
/// again in the new page after a navigation. `browser.page.screenshot`
/// captures the viewport, the whole page, or one element. Before, neither
/// existed for app browser tabs.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageWaitTests {
    final class ScriptedEngine: BrowserPageEngine {
        let calls = Mutex<[BrowserPageOperation]>([])
        let respond: @Sendable (BrowserPageOperation, Int) throws -> JSONValue

        init(_ respond: @escaping @Sendable (BrowserPageOperation, Int) throws -> JSONValue) {
            self.respond = respond
        }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            let index = calls.withLock { calls in
                calls.append(operation)
                return calls.count - 1
            }
            return try respond(operation, index)
        }

        var operations: [BrowserPageOperation] { calls.withLock { $0 } }
    }

    func install(_ respond: @escaping @Sendable (BrowserPageOperation, Int) throws -> JSONValue) -> (ControlRouter, ScriptedEngine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let engine = ScriptedEngine(respond)
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let browser = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Example", url: "https://example.com/")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(browser)
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    func wait(_ router: ControlRouter, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = "tab_0123abcd"
        return await router.handle(ControlRequest(method: "browser.page.wait", params: params))
    }

    static func met(_ met: Bool, error: String? = nil) -> JSONValue {
        ["value": ["met": .bool(met), "error": error.map { .string($0) } ?? .null]]
    }

    func script(_ operation: BrowserPageOperation?) -> String {
        if case .evaluateAsync(let body) = operation { return body }
        return ""
    }

    @Test func aMetConditionAnswersWaitedForTheTab() async throws {
        let (router, engine) = install { _, _ in Self.met(true) }
        let result = try await wait(router, ["selector": "#q", "url_contains": "/done"]).get()
        #expect(result["waited"] == true)
        #expect(result["tab"] == "tab_0123abcd")
        // A selector wins over the other conditions, as in the old CLI.
        let body = script(engine.operations.first)
        #expect(body.contains("document.querySelector(raw)"))
        #expect(!body.contains("location.href"))
        #expect(body.contains("MutationObserver"))
    }

    @Test func conditionsFollowTheOldPrecedence() {
        typealias Condition = BrowserPageScripts.WaitCondition
        #expect(Condition.urlContains("/a").expression.contains("location.href"))
        #expect(Condition.textContains("Done").expression.contains("innerText"))
        #expect(Condition.loadState("interactive").expression.contains("'complete'"))
        #expect(Condition.loadState("complete").expression == "document.readyState === \"complete\"")
        #expect(Condition.function("window.ready").expression.contains("window.ready"))
        #expect(Condition.selector("@e3").expression.contains("data-cmux-ref"))
    }

    @Test func noConditionWaitsForTheDocumentToLoad() async throws {
        let (router, engine) = install { _, _ in Self.met(true) }
        _ = try await wait(router, [:]).get()
        #expect(script(engine.operations.first).contains("document.readyState === \"complete\""))
    }

    @Test func anUnmetConditionTimesOutWithTheLastPageError() async {
        let (router, engine) = install { _, _ in Self.met(false, error: "TypeError: x") }
        let result = await wait(router, ["function": "window.x.ready", "timeout_ms": 200])
        #expect(result.failure?.code == "timeout")
        #expect(result.failure?.data?["timeout_ms"] == 200)
        #expect(result.failure?.data?["last_error"] == "TypeError: x")
        // An answer that came before the page's timer is spaced by Backoff, not repeated at once.
        #expect((1...5).contains(engine.operations.count))
        #expect(script(engine.operations.first).contains("setTimeout(() => finish(check()), "))
        #expect(script(engine.operations.first).contains("setInterval(onEvent, 100)"))
    }

    @Test func longWaitsRunInPageChunksAndDomWaitsUseNoPageTimer() async throws {
        let (router, engine) = install { _, _ in Self.met(true) }
        _ = try await wait(router, ["selector": "#q", "timeout_ms": 60_000]).get()
        let body = script(engine.operations.first)
        #expect(body.contains("finish(check()), 4000)"))
        #expect(!body.contains("setInterval"))
    }

    @Test func aNavigationStartsTheWaitAgainInTheNewPage() async throws {
        let (router, engine) = install { _, index in
            if index == 0 { throw ControlError(code: "js_error", message: "javaScript(\"navigated\")") }
            return Self.met(true)
        }
        let result = try await wait(router, ["url_contains": "/next", "timeout_ms": 5_000]).get()
        #expect(result["waited"] == true)
        #expect(engine.operations.count == 2)
    }

    @Test func aConditionThatDoesNotParseFailsAtOnce() async {
        let (router, engine) = install { _, _ in
            throw ControlError(code: "js_error", message: "javaScript(\"SyntaxError: Unexpected token ')'\")")
        }
        let result = await wait(router, ["function": "(("])
        #expect(result.failure?.code == "js_error")
        #expect(result.failure?.message.contains("SyntaxError") == true)
        #expect(engine.operations.count == 1)
    }

    @Test func badTimeoutsAndLoadStatesAreRefusedBeforeThePageRuns() async {
        let (router, engine) = install { _, _ in Self.met(true) }
        for params: [String: JSONValue] in [["timeout_ms": 0], ["timeout_ms": 120_001], ["timeout_ms": "soon"], ["timeout_ms": 1.5],
                                            ["load_state": "networkidle"]] {
            #expect(await wait(router, params).failure?.code == "invalid_params")
        }
        #expect(engine.operations.isEmpty)
    }

    @Test func screenshotsTheViewportByDefaultAndTheWholePageOnRequest() async throws {
        let (router, engine) = install { _, _ in ["png_base64": "iVBO", "width": 800, "height": 600] }
        let shot = try await router.handle(ControlRequest(method: "browser.page.screenshot", params: ["tab": "tab_0123"])).get()
        #expect(shot["png_base64"] == "iVBO")
        #expect(shot["width"] == 800)
        #expect(shot["tab"] == "tab_0123abcd")
        _ = try await router.handle(ControlRequest(method: "browser.page.screenshot", params: ["tab": "tab_0123", "full_page": true])).get()
        #expect(engine.operations == [.screenshot(.viewport), .screenshot(.fullPage)])
    }

    @Test func anElementScreenshotClipsToWhereTheElementIs() async throws {
        let (router, engine) = install { operation, _ in
            if case .evaluate = operation {
                return ["value": ["value": ["x": 10, "y": 20, "width": 30, "height": 40, "viewport_width": 800, "viewport_height": 600]]]
            }
            return ["png_base64": "iVBO", "width": 60, "height": 80]
        }
        let shot = try await router.handle(ControlRequest(method: "browser.page.screenshot",
                                                          params: ["tab": "tab_0123abcd", "selector": "#hero"])).get()
        #expect(shot["selector"] == "#hero")
        let clip = BrowserPageClip(x: 10, y: 20, width: 30, height: 40, viewportWidth: 800, viewportHeight: 600)
        #expect(engine.operations.last == .screenshot(.clip(clip)))
        if case .evaluate(let script) = engine.operations.first {
            #expect(script.contains("scrollIntoView"))
        } else {
            Issue.record("expected the element script first")
        }
    }

    @Test func aMissingElementOrConflictingScopeIsRefused() async {
        let (router, engine) = install { operation, _ in
            if case .evaluate = operation { return ["value": ["error": "Element not found: #nope"]] }
            return ["png_base64": "iVBO", "width": 1, "height": 1]
        }
        let missing = await router.handle(ControlRequest(method: "browser.page.screenshot",
                                                         params: ["tab": "tab_0123abcd", "selector": "#nope"]))
        #expect(missing.failure?.code == "not_found")
        let both = await router.handle(ControlRequest(method: "browser.page.screenshot",
                                                      params: ["tab": "tab_0123abcd", "selector": "#a", "full_page": true]))
        #expect(both.failure?.code == "invalid_params")
        #expect(!engine.operations.contains { if case .screenshot = $0 { true } else { false } })
    }
}
