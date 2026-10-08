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
        return AgentPaneHandshake.acpmux(AcpmuxConnection(url: URL(fileURLWithPath: "/"), dashboardToken: "t", localAppToken: nil), sessionId: sessionId)
    }
    func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        reconnects += 1
        return AgentPaneHandshake.acpmux(AcpmuxConnection(url: URL(fileURLWithPath: "/"), dashboardToken: "t", localAppToken: nil), sessionId: sessionId)
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

    /// The page formats its links in this build's scheme, handed over with
    /// the handshake next to the other bootstrap values.
    @Test func theHandshakeCarriesTheLinkScheme() async throws {
        let model = AgentPaneModel(host: RecordingHost())
        model.linkScheme = "cmux-dev-mytag"
        let value = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(value["linkScheme"] as? String == "cmux-dev-mytag")
        let reconnect = try #require(await model.respond(to: .reconnect)["value"] as? [String: Any])
        #expect(reconnect["linkScheme"] as? String == "cmux-dev-mytag")
        let unset = try #require(await AgentPaneModel(host: MockAgentPaneHost()).respond(to: .ready)["value"] as? [String: Any])
        #expect(unset["linkScheme"] == nil)
    }

    /// A tab a `cmux://session/<id>` link opened asks the page to refuse a
    /// session the daemon does not have, until the page reports one it shows.
    @Test func aLinkedSessionMustExistUntilThePageReportsOne() async throws {
        let model = AgentPaneModel(host: RecordingHost(), sessionId: "s1")
        model.sessionMustExist = true
        let value = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(value["sessionMustExist"] as? Bool == true)
        #expect(value["sessionId"] as? String == "s1")
        _ = await model.respond(to: .persistSession("s2"))
        let after = try #require(await model.respond(to: .reconnect)["value"] as? [String: Any])
        #expect(after["sessionMustExist"] == nil)
        // A tab opened any other way, or a new chat, falls back as before.
        let plain = try #require(await AgentPaneModel(host: RecordingHost(), sessionId: "s1").respond(to: .ready)["value"] as? [String: Any])
        #expect(plain["sessionMustExist"] == nil)
        let fresh = AgentPaneModel(host: RecordingHost())
        fresh.sessionMustExist = true
        let freshValue = try #require(await fresh.respond(to: .ready)["value"] as? [String: Any])
        #expect(freshValue["sessionMustExist"] == nil)
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

    /// Composer text is kept by the app-owned store, so a private WebKit page can
    /// drop its local storage while the session's unsent prompt survives.
    @Test func composerDraftsRoundTripThroughTheNativeStore() async throws {
        let suite = "cmux.agent-pane-draft-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAgentPaneDraftStore(defaults: defaults, keyPrefix: "draft.")
        let model = AgentPaneModel(host: MockAgentPaneHost(), draftStore: store)
        #expect(
            AgentPaneRequest(body: ["method": "chat.readDraft", "params": ["sessionId": "session-1"]] as [String: Any])
                == .readDraft("session-1")
        )
        #expect(
            AgentPaneRequest(body: ["method": "chat.writeDraft", "params": ["sessionId": "session-1", "text": "keep this"]] as [String: Any])
                == .writeDraft("session-1", text: "keep this")
        )
        let write = await model.respond(to: .writeDraft("session-1", text: "keep this"))
        #expect(write["ok"] as? Bool == true)
        let read = await model.respond(to: .readDraft("session-1"))
        #expect(read["value"] as? String == "keep this")
        _ = await model.respond(to: .writeDraft("session-1", text: "   "))
        let cleared = await model.respond(to: .readDraft("session-1"))
        #expect(cleared["value"] is NSNull)
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
    }

    @Test func aMissingDaemonFailsWithoutIO() async throws {
        let reply = await AgentPaneModel(host: AcpmuxHost(environment: nil)).respond(to: .ready)
        #expect((reply["error"] as? [String: Any])?["userMessage"] as? String == AgentPaneHostError.userMessage(for: AgentPaneHostError.acpmuxNotFound))
    }

    /// The page shows this message as the next step, so it names every
    /// install directory the host searches besides PATH.
    @Test func aMissingAcpmuxSaysWhereToInstallIt() {
        let message = AgentPaneHostError.userMessage(for: AgentPaneHostError.acpmuxNotFound)
        for directory in ["~/.local/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            #expect(message.contains(directory), "\(message) should name \(directory)")
        }
        let candidates = AcpmuxEnvironment.executableCandidates(
            bundledBinDirectory: nil, environment: [:], userHome: URL(fileURLWithPath: "/Users/me")
        ).map(\.path)
        #expect(candidates == [
            "/Users/me/.local/bin/acpmux", "/Users/me/.cargo/bin/acpmux", "/opt/homebrew/bin/acpmux", "/usr/local/bin/acpmux",
        ])
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

    /// Onboarding's first task: the prompt goes to the page once, so a
    /// reload does not run the task again.
    @Test func aSeededPromptIsHandedOutOnce() async throws {
        let model = AgentPaneModel(host: RecordingHost(), seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp/w", prompt: "Leave a note")))
        let first = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(first["prompt"] as? String == "Leave a note")
        #expect(first["draft"] == nil)
        let reload = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(reload["prompt"] == nil)
    }

    /// A resumed chat: the page gets the adopt on every handshake until the
    /// tab has a session (acpmux adopts one id once), then never again.
    @Test func aSeededAdoptReachesThePageUntilTheTabHasASession() async throws {
        let adopt = AgentPaneAdopt(harness: "claude", agentSessionId: "0a1b2c3d")
        let model = AgentPaneModel(host: RecordingHost(), seed: AgentPaneSeedSource(AgentPaneSeed(adopt: adopt)))
        let expected = ["harness": "claude", "agentSessionId": "0a1b2c3d"]
        let first = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(first["adopt"] as? [String: String] == expected)
        let reload = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(reload["adopt"] as? [String: String] == expected)
        _ = await model.respond(to: .persistSession("s-1"))
        let attached = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(attached["adopt"] == nil)
    }

    /// A chat that reopens a session ignores the seed.
    @Test func aSessionTabIgnoresTheSeed() async throws {
        let model = AgentPaneModel(host: RecordingHost(), sessionId: "s-2", seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp/w", draft: "hi")))
        let value = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(value["cwd"] == nil)
        #expect(value["draft"] == nil)
    }

    /// The quick panel's page lays itself out from the handshake's
    /// `surface`, on every ready, after the chat has a session too.
    @Test func aQuickSeedPutsItsSurfaceInEveryHandshake() async throws {
        let model = AgentPaneModel(host: RecordingHost(), seed: AgentPaneSeedSource(AgentPaneSeed(surface: .quick)))
        let first = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(first["surface"] as? String == "quick")
        _ = await model.respond(to: .persistSession("s-3"))
        let attached = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(attached["surface"] as? String == "quick")
        let reconnect = try #require(await model.respond(to: .reconnect)["value"] as? [String: Any])
        #expect(reconnect["surface"] as? String == "quick")
    }

    @Test func aTabHandshakeHasNoSurface() async throws {
        let plain = try #require(await AgentPaneModel(host: RecordingHost()).respond(to: .ready)["value"] as? [String: Any])
        #expect(plain["surface"] == nil)
        let seeded = AgentPaneModel(host: RecordingHost(), seed: AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp/w")))
        let value = try #require(await seeded.respond(to: .ready)["value"] as? [String: Any])
        #expect(value["surface"] == nil)
    }

    @Test func quickPanelMessagesDecode() {
        #expect(AgentPaneRequest(body: ["method": "quick.dismiss"] as [String: Any]) == .quickDismiss)
        #expect(AgentPaneRequest(body: ["method": "quick.dismiss", "params": [String: Any]()] as [String: Any]) == .quickDismiss)
        #expect(AgentPaneRequest(body: ["method": "quick.openInWindow", "params": ["sessionId": "s-4"]] as [String: Any])
            == .quickOpenInWindow(sessionId: "s-4"))
        #expect(AgentPaneRequest(body: ["method": "quick.openInWindow", "params": ["sessionId": ""]] as [String: Any])
            == .quickOpenInWindow(sessionId: nil))
        #expect(AgentPaneRequest(body: ["method": "quick.openInWindow"] as [String: Any]) == .quickOpenInWindow(sessionId: nil))
    }

    /// `quick.dismiss` hides the panel; `quick.openInWindow` hands the
    /// chat to the main window with the page's session, else the one it
    /// last persisted.
    @Test func quickPanelMessagesReachTheirClosures() async throws {
        let model = AgentPaneModel(host: RecordingHost())
        var dismissed = 0
        var opened: [String?] = []
        var reported: [String] = []
        model.onQuickDismiss = { dismissed += 1 }
        model.onQuickOpenInWindow = { opened.append($0) }
        model.onSessionChange = { reported.append($0) }

        #expect(await model.respond(to: .quickDismiss)["ok"] as? Bool == true)
        #expect(dismissed == 1)

        #expect(await model.respond(to: .quickOpenInWindow(sessionId: nil))["ok"] as? Bool == true)
        _ = await model.respond(to: .persistSession("s-5"))
        _ = await model.respond(to: .quickOpenInWindow(sessionId: nil))
        _ = await model.respond(to: .quickOpenInWindow(sessionId: "s-6"))
        #expect(opened == [nil, "s-5", "s-6"])
        #expect(reported == ["s-5", "s-6"])
        #expect(model.sessionId == "s-6")
    }

    /// A pane tab is not the quick panel: it refuses both messages.
    @Test func aTabRefusesQuickPanelMessages() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        for request in [AgentPaneRequest.quickDismiss, .quickOpenInWindow(sessionId: "s-7")] {
            let reply = await model.respond(to: request)
            #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
        }
        #expect(model.sessionId == nil)
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
        #expect(value["transport"] as? String == "acpmux-bridge")
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
