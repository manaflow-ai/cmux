@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// `cmux browser <tab> click|fill|type|press|hover|…` run page scripts, so
/// no browser host event reports them; the service announces each to the
/// engine with the element the script measured, and the app draws the
/// agent cursor there (user, 2026-10-18).
@Suite(.timeLimit(.minutes(1))) struct BrowserPageAgentInputTests {
    final class AnnouncingEngine: BrowserPageEngine {
        let announced = Mutex<[BrowserPageAgentInput]>([])
        let answer: JSONValue

        init(_ answer: JSONValue) { self.answer = answer }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            ["value": answer]
        }

        func announce(_ input: BrowserPageAgentInput, tabID: String) async {
            announced.withLock { $0.append(input) }
        }

        var inputs: [BrowserPageAgentInput] { announced.withLock { $0 } }
    }

    static let field: JSONValue = ["value": true, "at": ["x": 10, "y": 20, "w": 200, "h": 30, "secret": false]]

    func install(_ answer: JSONValue) -> (ControlRouter, AnnouncingEngine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let engine = AnnouncingEngine(answer)
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Form", url: "https://example.com/")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    func call(_ router: ControlRouter, _ verb: String, _ params: [String: JSONValue]) async throws {
        var params = params
        params["tab"] = "tab_0123abcd"
        _ = try await router.handle(ControlRequest(method: "browser.page." + verb, params: params)).get()
    }

    @Test func actionsAnnounceWhereTheyLandedAndWhatTheyTyped() async throws {
        let (router, engine) = install(Self.field)
        try await call(router, "click", ["selector": "#go"])
        try await call(router, "fill", ["selector": "#q", "text": "cats"])
        try await call(router, "type", ["selector": "#q", "text": "!"])
        try await call(router, "press", ["key": "Enter"])
        let rect = BrowserPageAgentInput.Rect(x: 10, y: 20, width: 200, height: 30)
        #expect(engine.inputs == [
            BrowserPageAgentInput(kind: .click, rect: rect),
            BrowserPageAgentInput(kind: .type, rect: rect, text: "cats", replace: true),
            BrowserPageAgentInput(kind: .type, rect: rect, text: "!"),
            BrowserPageAgentInput(kind: .key, rect: rect, key: "Enter"),
        ])
    }

    @Test func readsAnnounceNothingAndAFieldThatDoesNotSayIsSecret() async throws {
        let (router, engine) = install(["value": "text"])
        try await call(router, "text", ["selector": "#q"])
        try await call(router, "value", ["selector": "#q"])
        #expect(engine.inputs.isEmpty)
        try await call(router, "fill", ["selector": "#pw", "text": "hunter2"])
        #expect(engine.inputs.last?.secret == true, "no measurement: treated as a password field")
        #expect(engine.inputs.last?.rect == nil)
    }

}
