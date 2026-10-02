import Foundation
import Testing
@testable import CmuxNextAgentPane

private nonisolated struct FailingHost: AgentPaneHostProviding {
    let error: AgentPaneHostError
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw error }
}

private actor RecordingHost: AgentPaneHostProviding {
    private(set) var asked: [String?] = []
    private(set) var reconnects = 0
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        asked.append(sessionId)
        return AgentPaneHandshake.acpmux(AcpmuxWebEndpoint(url: URL(fileURLWithPath: "/"), token: "t"), sessionId: sessionId)
    }
    func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        reconnects += 1
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

    /// `ready` with `reconnect: true` comes from a page that lost its daemon.
    @Test func aReconnectingPageGetsAHandshakeThatDoesNotStartTheDaemon() async throws {
        #expect(AgentPaneRequest(body: ["method": "ready", "params": ["reconnect": true]] as [String: Any]) == .reconnect)
        #expect(AgentPaneRequest(body: ["method": "ready", "params": [String: Any]()] as [String: Any]) == .ready)
        let host = RecordingHost()
        let model = AgentPaneModel(host: host)
        _ = await model.respond(to: .reconnect)
        #expect(await host.reconnects == 1)
        #expect(await host.asked.isEmpty)
    }

    /// Saved replies true, a cancelled panel false, and no saver or a failed
    /// write a failure the page answers by copying the log.
    @Test func theInspectorExportRepliesSavedCancelledOrFailed() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let request = AgentPaneRequest.saveLog(text: "{}\n", suggestedName: "acp.jsonl")
        #expect(await model.respond(to: request)["ok"] as? Bool == false)
        // The saver gets the page's text and name; it reports a mismatch as a cancel.
        model.onSaveLog = { text, name in text == "{}\n" && name == "acp.jsonl" }
        let reply = await model.respond(to: request)
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["value"] as? Bool == true)
        model.onSaveLog = { _, _ in false }
        #expect(await model.respond(to: request)["value"] as? Bool == false)
        model.onSaveLog = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let failed = await model.respond(to: request)
        #expect(failed["ok"] as? Bool == false)
        #expect((failed["error"] as? [String: Any])?["code"] as? String == "save_failed")
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
        #expect((reply["error"] as? [String: Any])?["userMessage"] as? String == AgentPaneHostError.userMessage(for: AgentPaneHostError.acpmuxNotFound))
    }

    @Test func unsupportedRequestsAreRefused() async {
        let reply = await AgentPaneModel(host: MockAgentPaneHost()).respond(to: .unsupported("chat.send"))
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
    }
}
