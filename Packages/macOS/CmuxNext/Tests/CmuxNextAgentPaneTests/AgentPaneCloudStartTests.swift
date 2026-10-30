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
        // A chat that started on the machine keeps the hold: this pane starts nothing more.
        #expect(!model.transport.replacements.beginSandbox())
    }

    @Test func aRefusedStartReleasesTheHoldSoTheSendMayBeTriedAgain() async {
        let model = AgentPaneModel(host: NoHost())
        model.onCloudStartChat = { _ in AgentPaneReply.failure(code: "cloud_start_failed", message: "no machine") }
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.start(Self.good))
        #expect(reply["ok"] as? Bool == false)
        #expect(model.transport.replacements.beginSandbox())
    }

    @Test func noGestureAStartedOrRemoteChatOrABadRequestStartsNothing() async {
        let starts = Starts()
        _ = await Self.pane(starts).respond(to: Self.start(Self.good))
        let started = Self.pane(starts, sessionId: "chat")
        started.transport.gestures.record()
        _ = await started.respond(to: Self.start(Self.good))
        let starting = Self.pane(starts)
        starting.transport.gestures.record()
        starting.transport.replacements.set(waiting: 1)
        _ = await starting.respond(to: Self.start(Self.good))
        // A chat on another machine names its own paths, never a folder on this Mac to copy.
        let remote = Self.pane(starts)
        remote.remoteChat = true
        remote.transport.gestures.record()
        #expect(await remote.respond(to: Self.start(Self.good))["ok"] as? Bool != true)
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

    @Test func theMachinesSeedKeepsTheRequestedHarnessAndModel() throws {
        let start = try #require(AgentPaneCloudStart(params: Self.good))
        let seed = start.seed(cwd: "/home/cloud/src/paint")
        #expect(seed.cwd == "/home/cloud/src/paint")
        #expect(seed.prompt == "fix the build")
        #expect(seed.promptBy == .person)
        #expect(seed.harness == "codex")
        #expect(seed.model == "gpt-6-astra")
        // No model picked: the harness's own default on the machine.
        let plain = try #require(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString]))
        #expect(plain.seed(cwd: "/a").model == nil)
        #expect(plain.seed(cwd: "/a").harness == nil)
    }

    @Test func withoutARunnerTheMethodIsUnsupported() async {
        let model = AgentPaneModel(host: NoHost())
        model.transport.gestures.record()
        let reply = await model.respond(to: Self.start(Self.good))
        #expect(reply["ok"] as? Bool != true)
        #expect(AgentPaneCloudStart(params: ["task": "t", "cwd": "/a", "key": UUID().uuidString])?.harness == nil)
        // No folder from the page: the tab's own folder, on the App side.
        #expect(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString])?.cwd == nil)
    }
}
