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

    /// A new chat starts in the seed's cwd with its draft; the draft is
    /// handed out once, the cwd until the chat has a session (#16620).
    @Test func aNewChatStartsFromItsSeed() async throws {
        let model = AgentPaneModel(host: RecordingHost(), seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp/w", draft: "hi")))
        let first = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(first["cwd"] as? String == "/tmp/w")
        #expect(first["draft"] as? String == "hi")
        let reload = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(reload["cwd"] as? String == "/tmp/w")
        #expect(reload["draft"] == nil)
        _ = await model.respond(to: .persistSession("s-1"))
        let attached = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(attached["cwd"] == nil)
    }

    /// A chat that reopens a session ignores the seed.
    @Test func aSessionTabIgnoresTheSeed() async throws {
        let model = AgentPaneModel(host: RecordingHost(), sessionId: "s-2", seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp/w", draft: "hi")))
        let value = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(value["cwd"] == nil)
        #expect(value["draft"] == nil)
    }

    /// A seed read that never answers (a hung page) is dropped at its
    /// limit instead of holding the handshake.
    @Test func aSeedThatNeverAnswersIsDropped() async throws {
        let seed = AgentPaneSeedSource(limit: .milliseconds(50)) {
            try? await Task.sleep(for: .seconds(5))
            return AgentPaneSeed(cwd: "/late")
        }
        let model = AgentPaneModel(host: RecordingHost(), seed: seed)
        let value = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(value["transport"] as? String == "acpmux-websocket")
        #expect(value["cwd"] == nil)
    }
}

/// The page's `pane.context` answer (#16620).
@Suite struct AgentPaneContextTests {
    @Test func readsTheCwdAndWebURLs() {
        let context = AgentPaneContext(page: ["cwd": "/w/app", "urls": ["http://localhost:5173/", "javascript:alert(1)", 7, "https://github.com/o/r/pull/2"]])
        #expect(context == AgentPaneContext(cwd: "/w/app", urls: [URL(string: "http://localhost:5173/")!, URL(string: "https://github.com/o/r/pull/2")!]))
    }

    @Test func anEmptyOrMissingAnswerIsNotAContext() {
        #expect(AgentPaneContext(page: nil) == nil)
        #expect(AgentPaneContext(page: ["cwd": "", "urls": []]) == AgentPaneContext())
    }
}
