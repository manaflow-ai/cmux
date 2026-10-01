@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// `browser.page.press|hover|scroll|scroll_into_view|select|check|uncheck`
/// follow the old `cmux browser` input verbs: page scripts that report
/// `not_checkable`, `disabled` and `not_changed` as the old app did. Before,
/// app browser tabs had only click, fill, type and focus.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageInputTests {
    final class ScriptEngine: BrowserPageEngine {
        let scripts = Mutex<[String]>([])
        let answer: JSONValue

        init(_ answer: JSONValue) { self.answer = answer }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            if case .evaluate(let script) = operation { scripts.withLock { $0.append(script) } }
            return ["value": answer]
        }

        var last: String { scripts.withLock { $0.last ?? "" } }
        var count: Int { scripts.withLock { $0.count } }
    }

    func install(_ answer: JSONValue = ["value": true]) -> (ControlRouter, ScriptEngine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let engine = ScriptEngine(answer)
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Form", url: "https://example.com/")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    func call(_ router: ControlRouter, _ verb: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = "tab_0123abcd"
        return await router.handle(ControlRequest(method: "browser.page." + verb, params: params))
    }

    @Test func keyNamesResolveAsTheOldAppDid() {
        let enter = BrowserPageKey("Enter")
        #expect(enter.code == "Enter" && enter.keyCode == 13)
        #expect(BrowserPageKey("space").key == " ")
        #expect(BrowserPageKey("Esc").key == "Escape")
        #expect(BrowserPageKey("F5").keyCode == 116)
        #expect(BrowserPageKey("a") == BrowserPageKey("KeyA"))
        #expect(BrowserPageKey("A").key == "A" && BrowserPageKey("A").keyCode == 65)
        #expect(BrowserPageKey("7").code == "Digit7")
        // US-layout punctuation keeps its code, as page shortcuts check it.
        #expect(BrowserPageKey("/").code == "Slash" && BrowserPageKey("/").keyCode == 191)
        #expect(BrowserPageKey("?").code == "Slash")
        #expect(BrowserPageKey("Shift").location == 1 && BrowserPageKey("NumpadEnter").location == 3)
        // Other characters keep their UTF-16 unit; unknown names pass through.
        #expect(BrowserPageKey("é").code == "" && BrowserPageKey("é").keyCode == 0xE9)
        #expect(BrowserPageKey("Hyper").code == "Hyper" && BrowserPageKey("Hyper").keyCode == 0)
    }

    @Test func pressDispatchesToTheFocusedElementOrTheSelector() async throws {
        let (router, engine) = install()
        _ = try await call(router, "press", ["key": "Enter"]).get()
        #expect(engine.last.contains("document.activeElement"))
        #expect(engine.last.contains("requestSubmit"))
        _ = try await call(router, "press", ["key": "Space", "selector": "#agree"]).get()
        #expect(engine.last.contains("\"#agree\""))
        #expect(engine.last.contains("const key = \" \""))
        #expect(engine.last.contains("location = 0"))
        #expect(await call(router, "press", ["key": ""]).failure?.code == "invalid_params")
        #expect(engine.count == 2)
    }

    @Test func pageErrorsKeepTheirCodes() async {
        for code in ["not_checkable", "disabled", "not_changed"] {
            let (router, _) = install(["error": "nope", "code": .string(code)])
            let result = await call(router, "check", ["selector": "#a"])
            #expect(result.failure?.code == code)
            #expect(result.failure?.data?["selector"] == "#a")
        }
        let (router, _) = install(["error": "Element not found: #a"])
        #expect(await call(router, "hover", ["selector": "#a"]).failure?.code == "not_found")
    }

    @Test func checkAndUncheckAimForAState() async throws {
        let (router, engine) = install()
        _ = try await call(router, "check", ["selector": "#a"]).get()
        #expect(engine.last.contains("const desired = true"))
        _ = try await call(router, "uncheck", ["selector": "#a"]).get()
        #expect(engine.last.contains("const desired = false"))
        #expect(engine.last.contains("el.type === 'radio'"))
        #expect(engine.last.contains("el.type !== 'checkbox'"))
    }

    @Test func selectTakesAnyValueIncludingEmpty() async throws {
        let (router, engine) = install()
        let result = try await call(router, "select", ["selector": "#size", "value": ""]).get()
        #expect(result["tab"] == "tab_0123abcd")
        #expect(engine.last.contains("const next = \"\""))
        #expect(await call(router, "select", ["selector": "#size"]).failure?.code == "invalid_params")
    }

    @Test func scrollNeedsAnOffsetAndTakesAnOptionalSelector() async throws {
        let (router, engine) = install(["value": ["x": 0, "y": 400]])
        let page = try await call(router, "scroll", ["dy": 400]).get()
        #expect(page["value"]?["y"] == 400)
        #expect(engine.last.contains("window.scrollBy({ left: 0.0, top: 400.0"))
        _ = try await call(router, "scroll", ["dx": -50, "selector": "#list"]).get()
        #expect(engine.last.contains("el.scrollBy({ left: -50.0, top: 0.0"))
        #expect(await call(router, "scroll", [:]).failure?.code == "invalid_params")
        let far = await call(router, "scroll", ["dy": "far"])
        #expect(far.failure?.code == "invalid_params")
        #expect(far.failure?.message.contains("params.dy") == true)
        _ = try await call(router, "scroll_into_view", ["selector": "#footer"]).get()
        #expect(engine.last.contains("scrollIntoView({ block: 'center'"))
        _ = try await call(router, "hover", ["selector": "#menu"]).get()
        #expect(engine.last.contains("'mouseover'"))
    }
}
