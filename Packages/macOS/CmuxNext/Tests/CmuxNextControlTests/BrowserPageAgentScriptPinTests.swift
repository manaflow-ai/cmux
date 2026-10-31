@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import JavaScriptCore
import Testing

/// Executes the real service-generated JavaScript after a controlled navigation at the engine
/// boundary, including the expression-to-statements retry and async wait path.
@MainActor @Suite(.serialized) struct BrowserPageAgentScriptPinTests {
    @MainActor final class Engine: BrowserPageEngine {
        let context = JSContext()!
        var origin = "https://a.test"
        var evaluations = 0
        let navigateAt: Int

        init(navigateAt: Int) {
            self.navigateAt = navigateAt
            context.evaluateScript("this.location = {origin: 'https://a.test'}; this.executed = false;")
        }

        nonisolated func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            try await execute(operation)
        }

        func execute(_ operation: BrowserPageOperation) throws -> JSONValue {
            switch operation {
            case .state: return ["url": .string(origin)]
            case .evaluateIsolated: return ["value": ["origin": .string(origin), "opener": false]]
            case .evaluate(let script): return try evaluate(script)
            case .evaluateAsync(let body):
                _ = try evaluate("(async function() {\n\(body)\n}).call(this)")
                return ["value": ["met": true]]
            default: return [:]
            }
        }

        private func evaluate(_ script: String) throws -> JSONValue {
            evaluations += 1
            if evaluations == navigateAt {
                origin = "https://b.test"
                context.evaluateScript("this.location.origin = 'https://b.test';")
            }
            context.exception = nil
            let result = context.evaluateScript(script)
            if let exception = context.exception {
                throw ControlError(code: "js_error", message: exception.toString())
            }
            return ["value": result?.toObject().flatMap(JSONValue.init(foundation:)) ?? .null]
        }
    }

    @Test(arguments: ["expression", "statements", "wait"])
    func navigationBeforeExecutionCannotReachAFilledOrigin(_ mode: String) async throws {
        let engine = Engine(navigateAt: mode == "statements" ? 2 : 1)
        let guards = BrowserLoginGuards(file: nil)
        let reservation = await guards.beginFill(tab: "filled", profile: "profile", origins: ["https://b.test"])
        await guards.completeFill(reservation)
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        BrowserPageService(engine: engine, loginGuards: guards).install(on: router)
        var snapshot = ControlSnapshot.sample()
        var tab = ControlTabInfo(id: "tab_pin", surface: "12", kind: "browser", title: "Test", url: engine.origin)
        tab.browserProfileID = "profile"
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        let script = mode == "statements" ? "let assigned = 1; this.executed = true;" : "(this.executed = true)"
        let params: [String: JSONValue] = mode == "wait"
            ? ["tab": "tab_pin", "function": .string(script), "timeout_ms": 50]
            : ["tab": "tab_pin", "script": .string(script)]
        _ = await router.handle(ControlRequest(method: mode == "wait" ? "browser.page.wait" : "browser.page.eval", params: params))
        #expect(engine.context.objectForKeyedSubscript("executed")?.toBool() == false,
                "agent source executed after navigation to the filled origin via \(mode)")
    }
}
