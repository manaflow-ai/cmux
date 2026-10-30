import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// Runs `openBrowser` as an action whose work produces a value, the way
/// `window.screenshot` reports its PNG (`ActionRegistry.track(result:)`).
final class ResultExecutor: ControlActionExecutor {
    let value: Result<[String: ActionResultValue], ActionWorkFailure>

    init(_ value: Result<[String: ActionResultValue], ActionWorkFailure>) {
        self.value = value
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        let value = value
        let result: ActionResultWork = Task { @MainActor in value }
        let work: ActionWork = Task {
            if case .failure(let failure) = await result.value { return failure }
            return nil
        }
        return ControlActionRun(outcome: .ran, work: [work], results: [result])
    }
}

/// `action.run` answers the value an action's work produced as `result`, and
/// a failure with its own code (`screenshot.unavailable`) under that code, so
/// `cmux window screenshot` and the MCP tool get the PNG's path and size or
/// the reason there is none.
@Suite(.timeLimit(.minutes(1))) struct ActionRunResultTests {
    private func run(_ executor: ResultExecutor) async -> Result<JSONValue, ControlError> {
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        router.snapshots.publish { $0 = BrowserOpenSplitTests.snapshot() }
        return await router.handle(ControlRequest(id: "1", method: "action.run", params: ["action": "openBrowser"]))
    }

    @Test func theWorksValueIsTheReplysResult() async throws {
        let fields: [String: ActionResultValue] = [
            "path": .string("/tmp/shot.png"), "width": .int(640), "height": .int(400), "scale": .double(2), "inline": .bool(false),
        ]
        let reply = try await run(ResultExecutor(.success(fields))).get()
        #expect(reply["ran"] == true)
        let result = try #require(reply["result"], "\(reply)")
        #expect(result["path"] == "/tmp/shot.png")
        #expect(result["width"] == 640)
        #expect(result["height"] == 400)
        #expect(result["scale"] == 2)
        #expect(result["inline"] == false)
    }

    /// A list answer (`cloud list-machines`) reaches the caller as JSON arrays,
    /// objects and nulls, not as a string it has to parse again.
    @Test func structuredFieldsAnswerAsJSON() async throws {
        let fields: [String: ActionResultValue] = [
            "machines": .array([.object(["machine_id": .string("vm-1"), "created_at": .null])]),
            "account": .object(["signed_in": .bool(true)]),
        ]
        let reply = try await run(ResultExecutor(.success(fields))).get()
        let result = try #require(reply["result"], "\(reply)")
        #expect(result["machines"] == .array([.object(["machine_id": "vm-1", "created_at": .null])]))
        #expect(result["account"]?["signed_in"] == true)
    }

    @Test func aFailureWithItsOwnCodeAnswersThatCode() async {
        let failure = ActionWorkFailure(code: "screenshot.unavailable", reason: "The window is minimized")
        let reply = await run(ResultExecutor(.failure(failure)))
        guard case .failure(let error) = reply else {
            Issue.record("expected a failure, got \(reply)")
            return
        }
        #expect(error.code == "screenshot.unavailable")
        #expect(error.message == "The window is minimized")
        #expect(error.data?["reason"] == "The window is minimized")
    }
}
