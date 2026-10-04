@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// `browser.page.*` drives the page of an app browser tab named by its
/// public tab id (or unique prefix), else the focused tab, and refuses a tab
/// that is not an app browser. These are the `cmux browser tab_… …` verbs;
/// before, page commands existed only in the compat layer.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageServiceTests {
    final class FakeEngine: BrowserPageEngine {
        let calls = Mutex<[(BrowserPageOperation, String, String?)]>([])

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            calls.withLock { $0.append((operation, tabID, url)) }
            switch operation {
            case .state: return ["url": "https://example.com/", "title": "Example"]
            case .evaluate: return ["value": 42]
            default: return [:]
            }
        }
    }

    func install() -> (ControlRouter, FakeEngine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let engine = FakeEngine()
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        var browser = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Example", url: "https://example.com/")
        browser.browserProfileID = "a9e70000-0000-4000-8000-00000000c0de"
        let other = ControlTabInfo(id: "tab_0199ffff", surface: "13", kind: "browser", title: "Other")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs += [browser, other]
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    @Test func navigatesTheTabNamedByAUniquePrefix() async throws {
        let (router, engine) = install()
        let result = try await router.handle(ControlRequest(method: "browser.page.navigate",
                                                            params: ["tab": "tab_0123", "url": "https://cmux.com"])).get()
        #expect(result["tab"] == "tab_0123abcd")
        let calls = engine.calls.withLock { $0 }
        #expect(calls.count == 1)
        #expect(calls.first?.0 == .navigate("https://cmux.com"))
        #expect(calls.first?.1 == "tab_0123abcd")
        #expect(calls.first?.2 == "https://example.com/")
    }

    @Test func statesAndEvaluatesThroughTheEngine() async throws {
        let (router, _) = install()
        let state = try await router.handle(ControlRequest(method: "browser.page.state", params: ["tab": "tab_0123abcd"])).get()
        #expect(state["title"] == "Example")
        #expect(state["url"] == "https://example.com/")
        // Which browser profile the tab is in (agents check they got the clean agent profile).
        #expect(state["profile"] == "a9e70000-0000-4000-8000-00000000c0de")
        let other = try await router.handle(ControlRequest(method: "browser.page.state", params: ["tab": "tab_0199ffff"])).get()
        #expect(other["profile"] == "default")
        let evaluated = try await router.handle(ControlRequest(method: "browser.page.eval",
                                                               params: ["tab": "tab_0123abcd", "script": "6 * 7"])).get()
        #expect(evaluated["value"] == 42)
    }

    @Test func refusesAmbiguousUnknownAndNonBrowserTabs() async {
        let (router, engine) = install()
        let ambiguous = await router.handle(ControlRequest(method: "browser.page.reload", params: ["tab": "tab_01"]))
        #expect(ambiguous.failure?.code == "ambiguous")
        let missing = await router.handle(ControlRequest(method: "browser.page.reload", params: ["tab": "tab_ffff"]))
        #expect(missing.failure?.code == "not_found")
        // The sample's focused tab is a terminal.
        let terminal = await router.handle(ControlRequest(method: "browser.page.reload"))
        #expect(terminal.failure?.code == "invalid_params")
        #expect(engine.calls.withLock { $0 }.isEmpty)
    }
}
