import Foundation
import Testing
@testable import CmuxNextAgentPane

private nonisolated struct FailingHost: AgentPaneHostProviding {
    let error: AgentPaneHostError
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw error }
}

private actor RecordingHost: AgentPaneHostProviding {
    private(set) var asked: [String?] = []
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        asked.append(sessionId)
        return AgentPaneHandshake.acpmux(AcpmuxWebEndpoint(url: URL(fileURLWithPath: "/"), token: "t"), sessionId: sessionId)
    }
}

@MainActor
@Suite struct AgentPaneModelTests {
    @Test func theMockHostAnswersReadyWithTheMockTransport() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["transport"] as? String == "mock")
    }

    /// Reloading the page reattaches the session it reported, not a new one.
    @Test func thePersistedSessionIsHandedBackOnTheNextReady() async throws {
        let host = RecordingHost()
        let model = AgentPaneModel(host: host)
        var reported: [String] = []
        model.onSessionChange = { reported.append($0) }
        _ = await model.respond(to: .ready)
        _ = await model.respond(to: .persistSession("s-9"))
        _ = await model.respond(to: .persistSession("s-9"))
        _ = await model.respond(to: .ready)
        #expect(await host.asked == [nil, "s-9"])
        #expect(reported == ["s-9"])
        #expect(model.sessionId == "s-9")
    }

    @Test func aHostFailureBecomesALocalizedMessage() async throws {
        let model = AgentPaneModel(host: FailingHost(error: .daemonFailed(logPath: "/tmp/acpmux/daemon.log")))
        let reply = await model.respond(to: .ready)
        #expect(reply["ok"] as? Bool == false)
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "host_unavailable")
        #expect((error["userMessage"] as? String)?.contains("/tmp/acpmux/daemon.log") == true)
        #expect(model.lastError != nil)
    }

    @Test func aMissingDaemonFailsWithoutIO() async throws {
        let reply = await AgentPaneModel(host: AcpmuxHost(environment: nil)).respond(to: .ready)
        #expect((reply["error"] as? [String: Any])?["userMessage"] as? String == AgentPaneStrings.message(for: AgentPaneHostError.acpmuxNotFound))
    }

    @Test func unsupportedRequestsAreRefused() async {
        let reply = await AgentPaneModel(host: MockAgentPaneHost()).respond(to: .unsupported("chat.send"))
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
    }
}
