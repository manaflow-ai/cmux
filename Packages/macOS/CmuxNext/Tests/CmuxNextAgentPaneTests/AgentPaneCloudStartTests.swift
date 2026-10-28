import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat's first send with Cloud picked (`cloud.startChat`): like a Sandboxed send, only a
/// new chat with a fresh gesture reaches the App's runner, with its prompt, folder and agent, and
/// while it runs no chat starts here.
@Suite
@MainActor
struct AgentPaneCloudStartTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Starts { var seen: [AgentPaneCloudStart] = []; var heldDuringRun: Bool? }

    private static func pane(_ starts: Starts, sessionId: String? = nil) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: sessionId)
        model.onCloudStartChat = { [weak model] start in
            starts.seen.append(start)
            // A second hand-off in the same pane is refused while this one runs.
            starts.heldDuringRun = model?.transport.replacements.beginSandbox() == false
            return AgentPaneReply.success(["machine": "cloud-1"])
        }
        return model
    }

    private static func start(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "cloud.startChat", "params": params])
    }

    private static let good: [String: Any] = ["task": "fix the build", "cwd": "/Users/me/src/paint", "harness": "codex", "model": "gpt-6-astra",
                                              "key": UUID().uuidString]

    @Test func aNewChatsSendWithAGestureStartsInCloud() async {
        let starts = Starts()
        let model = Self.pane(starts)
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.start(Self.good))
        #expect(reply["ok"] as? Bool == true)
        #expect(starts.seen.map(\.task) == ["fix the build"])
        #expect(starts.seen.first?.cwd == "/Users/me/src/paint")
        #expect(starts.seen.first?.harness == "codex")
        #expect(starts.seen.first?.model == "gpt-6-astra")
        #expect(starts.heldDuringRun == true)
        // The hold ends with the run: a later hand-off may take it.
        #expect(model.transport.replacements.beginSandbox())
    }

    @Test func noGestureAStartedChatOrABadRequestStartsNothing() async {
        let starts = Starts()
        _ = await Self.pane(starts).respond(to: Self.start(Self.good))
        let started = Self.pane(starts, sessionId: "chat")
        started.transport.gestures.record()
        _ = await started.respond(to: Self.start(Self.good))
        let starting = Self.pane(starts)
        starting.transport.gestures.record()
        starting.transport.replacements.set(waiting: 1)
        _ = await starting.respond(to: Self.start(Self.good))
        for bad: [String: Any] in [
            Self.good.merging(["task": "  "]) { $1 }, Self.good.merging(["cwd": "relative/path"]) { $1 },
            Self.good.merging(["key": "not-a-uuid"]) { $1 }, Self.good.merging(["harness": 3]) { $1 },
            Self.good.merging(["harness": String(repeating: "x", count: 200)]) { $1 },
        ] {
            let model = Self.pane(starts)
            model.transport.gestures.record()
            let reply = await model.respond(to: Self.start(bad))
            #expect(reply["ok"] as? Bool != true)
        }
        #expect(starts.seen.isEmpty)
    }

    @Test func withoutARunnerTheMethodIsUnsupported() async {
        let model = AgentPaneModel(host: NoHost())
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.start(Self.good))
        #expect(reply["ok"] as? Bool != true)
        #expect(AgentPaneCloudStart(params: ["task": "t", "cwd": "/a", "key": UUID().uuidString])?.harness == nil)
    }
}
