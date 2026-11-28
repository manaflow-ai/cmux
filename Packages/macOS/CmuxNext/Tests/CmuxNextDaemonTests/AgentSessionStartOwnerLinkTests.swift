import Foundation
import os
import Testing
@testable import CmuxNextDaemon

/// A chat starts on a Cloud machine only on the Cloud API's owner answer for the link the start
/// goes over, checked as it is sent and through any daemon: the guest's own record never counts
/// (agents keep sudo there), and an older daemon that would trust it gets no start without it.
@Suite(.timeLimit(.minutes(1))) struct AgentSessionStartOwnerLinkTests {
    private actor Answers {
        var ids: [Int?]
        init(_ ids: [Int?]) { self.ids = ids }
        func next() -> Int? { ids.isEmpty ? nil : ids.removeFirst() }
    }

    /// A link that answers `ids` in turn (before the connection, as the start is sent), then nil.
    private func link(_ ids: Int?...) -> AgentSessionAttachClient.OwnerLink {
        let answers = Answers(ids)
        return { await answers.next() }
    }

    /// The client's refusal code, if any, and the `agent-session-start` frame the daemon got.
    private func start(serving extra: [String], ownerLink: AgentSessionAttachClient.OwnerLink?, harness: String? = nil,
                       credentials: [String: String]? = nil, credentialConnection: String? = nil) async throws
        -> (refusal: String?, frame: [String: Any]?) {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-start-v1"] + extra)
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        var refusal: String?
        do {
            _ = try await client.start(cwd: "/w", harness: harness, ownerLink: ownerLink, credentials: credentials,
                                       credentialConnection: credentialConnection)
        } catch let error as AgentSessionAttachError {
            refusal = error.code
        }
        await client.close()
        return (refusal, daemon.frames.first { $0["cmd"] as? String == "agent-session-start" })
    }

    @Test func aCloudStartGoesOutOnlyOnTheOwnerAnswerOfTheSameLink() async throws {
        let vmKind = [DaemonCapability.agentSessionStartVMKind.rawValue]
        let owned = try await start(serving: vmKind, ownerLink: link(3, 3))
        #expect(owned.frame?["vm_kind"] as? String == "owner")

        // The link ended, or came up again with the Cloud API asked again, before the send.
        for answers in [link(3, 4), link(3, nil)] {
            let stale = try await start(serving: vmKind, ownerLink: answers)
            #expect(stale.refusal == "agent_session.host_unverified")
            #expect(stale.frame == nil, "an owner answer from another link was sent")
        }

        // No owner answer: no start through a daemon that takes vm_kind, nor through an older one
        // (it would take the VM's own record).
        for extra in [vmKind, []] {
            let refused = try await start(serving: extra, ownerLink: link(nil, nil))
            #expect(refused.refusal == "agent_session.host_unverified")
            #expect(refused.frame == nil, "\(extra)")
        }

        // The owner through an older daemon: no param it would refuse.
        let older = try await start(serving: [], ownerLink: link(5, 5))
        #expect(older.frame != nil)
        #expect(older.frame?["vm_kind"] == nil)
    }

    /// A Codex start that carries the owner's credential goes only to a machine whose acpmux keeps the provider override
    /// (cmux#45774): an older one takes credentials yet drops the override, and Codex runs on no key there. That start is
    /// refused before it is sent, with the code the remote start answers by updating the machine.
    @Test func aCodexCredentialGoesOnlyToADaemonThatRunsItsProvider() async throws {
        let owner = [DaemonCapability.agentSessionStartVMKind.rawValue, AgentSessionAttachClient.startCredentialsCapability]
        let token = ["CMUX_CHATGPT_ACCESS_TOKEN": "tok"]
        let older = try await start(serving: owner, ownerLink: link(3, 3), harness: "codex", credentials: token)
        #expect(older.refusal == AgentSessionAttachClient.codexCredentialsUnsupported)
        #expect(older.frame == nil, "a Codex credential went to a daemon that drops its provider")

        let current = try await start(serving: owner + [AgentSessionAttachClient.startCodexCredentialsCapability],
                                      ownerLink: link(3, 3), harness: "codex", credentials: token)
        // The fake daemon answers every start with no session (agent_session.refused); only that it went out counts here.
        #expect(current.refusal != AgentSessionAttachClient.codexCredentialsUnsupported)
        #expect((current.frame?["credentials"] as? [String: Any])?["env"] as? [String: String] == token)

        // A Claude credential and a credential-less Codex start are unchanged on the older daemon.
        let claude = try await start(serving: owner, ownerLink: link(3, 3), harness: "claude", credentials: ["CLAUDE_CODE_OAUTH_TOKEN": "tok"])
        #expect(claude.refusal != AgentSessionAttachClient.codexCredentialsUnsupported)
        #expect(claude.frame != nil)
        let plain = try await start(serving: owner, ownerLink: link(3, 3), harness: "codex")
        #expect(plain.refusal != AgentSessionAttachClient.codexCredentialsUnsupported)
        #expect(plain.frame != nil)
        #expect(AgentSessionAttachClient.credentialsCapability(harness: "codex") == AgentSessionAttachClient.startCodexCredentialsCapability)
        #expect(AgentSessionAttachClient.credentialsCapability(harness: "claude") == AgentSessionAttachClient.startCredentialsCapability)
    }

    @Test func aSavedClaudeTokenStartsOnGuestsBeforeCredentialReattach() async throws {
        let vmKind = DaemonCapability.agentSessionStartVMKind.rawValue
        let credentials = [vmKind, AgentSessionAttachClient.startCredentialsCapability]
        let legacyName = ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-fixture"]
        let token = ["ANTHROPIC_AUTH_TOKEN": "sk-ant-oat01-fixture"]
        let route = "claude-token-2"
        let older = try await start(serving: credentials, ownerLink: link(3, 3), harness: "claude",
                                    credentials: token, credentialConnection: route)
        let current = try await start(serving: credentials + [AgentSessionAttachClient.startEndpointCredentialsCapability,
                                      "agent-session-credential-reattach-v1"], ownerLink: link(3, 3), harness: "claude",
                                      credentials: token, credentialConnection: route)
        let oldWire = try #require(older.frame?["credentials"] as? [String: Any])
        let newWire = try #require(current.frame?["credentials"] as? [String: Any])
        #expect(oldWire["env"] as? [String: String] == legacyName)
        #expect(oldWire["connection"] == nil)
        #expect(newWire["env"] as? [String: String] == token)
        #expect(newWire["connection"] as? String == route)

        let unsupported = try await start(serving: [vmKind], ownerLink: link(3, 3), harness: "claude",
                                          credentials: token, credentialConnection: route)
        #expect(unsupported.frame == nil)
    }

    @Test(arguments: [false, true])
    func aSavedAPIKeyRequiresWithdrawalAndAReattachBinding(supported: Bool) async throws {
        let capabilities = [DaemonCapability.agentSessionStartVMKind.rawValue, AgentSessionAttachClient.startCredentialsCapability]
            + (supported ? [AgentSessionAttachClient.boundCredentialsCapability, "agent-session-credential-reattach-v1"] : [])
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-start-v1"] + capabilities)
        defer { daemon.stop() }
        let key = ["ANTHROPIC_API_KEY": "fixture-key"]
        let binding = "anthropic-key:" + String(repeating: "a", count: 64)
        for connection in ["anthropic-key", binding] {
            let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
            do {
                _ = try await client.start(cwd: "/w", harness: "claude", ownerLink: link(3, 3), credentials: key, credentialConnection: connection)
            } catch let error as AgentSessionAttachError {
                #expect((error.code != AgentSessionAttachClient.endpointCredentialsUnsupported) == (supported && connection == binding))
            }
            await client.close()
        }
        let prewarm = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        #expect(try await !prewarm.prewarm(cwd: "/w", harness: "claude", ownerLink: link(3, 3), credentials: key))
        await prewarm.close()
        let starts = daemon.frames.filter { $0["cmd"] as? String == "agent-session-start" }
        #expect(starts.count == (supported ? 1 : 0))
        if supported {
            #expect((starts.first?["credentials"] as? [String: Any])?["connection"] as? String == binding)
        }
        #expect(!daemon.frames.contains { $0["cmd"] as? String == "agent-session-prewarm" })
    }

    @Test(arguments: ["GEMINI_API_KEY", "GOOGLE_API_KEY", "XAI_API_KEY"])
    func aSavedNativeKeyStartsOnGuestsWithoutEndpointSupport(variable: String) async throws {
        let capability = AgentSessionAttachClient.boundCredentialsCapability
        let harness = variable == "XAI_API_KEY" ? "grok" : "gemini"
        let credentials = [variable: "fixture-key"]
        let binding = "native-key:" + String(repeating: "a", count: 64)
        let reply = try await start(serving: [
            DaemonCapability.agentSessionStartVMKind.rawValue, AgentSessionAttachClient.startCredentialsCapability,
            capability, "agent-session-credential-reattach-v1",
        ], ownerLink: link(3, 3), harness: harness, credentials: credentials, credentialConnection: binding)
        let wire = try #require(reply.frame?["credentials"] as? [String: Any])
        #expect(wire["env"] as? [String: String] == credentials)
        #expect(wire["endpoint"] == nil)
        #expect(AgentSessionAttachClient.credentialsCapability(harness: harness, nativeKey: true) == capability)
    }

    @Test(arguments: ["GEMINI_API_KEY", "GOOGLE_API_KEY", "XAI_API_KEY"])
    func aSavedNativeKeyNeverGoesToAnUnboundPrewarm(variable: String) async throws {
        let daemon = try PresenceDaemon(capabilities: [
            "agent-session-attach-v1", "agent-session-start-v1", AgentSessionAttachClient.prewarmCapability,
            DaemonCapability.agentSessionStartVMKind.rawValue, AgentSessionAttachClient.startCredentialsCapability,
            AgentSessionAttachClient.boundCredentialsCapability, "agent-session-credential-reattach-v1",
        ])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        let harness = variable == "XAI_API_KEY" ? "grok" : "gemini"
        _ = try await client.prewarm(cwd: "/w", harness: harness, ownerLink: link(3, 3),
                                     credentials: [variable: "fixture-key"])
        await client.close()
        #expect(!daemon.frames.contains { $0["cmd"] as? String == "agent-session-prewarm" })
    }

    @Test(arguments: [false, true])
    func credentialWritesRequireTheDurableSessionCapability(supported: Bool) async throws {
        var capabilities = ["agent-session-attach-v1", AgentSessionAttachClient.startCredentialsCapability]
        if supported { capabilities.append(AgentSessionAttachClient.boundCredentialsCapability) }
        let daemon = try PresenceDaemon(capabilities: capabilities)
        defer { daemon.stop() }
        for env in [["ANTHROPIC_API_KEY": "fixture-key"], [:]] {
            let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
            do {
                _ = try await client.updateCredentials(env, sessionID: "durable-chat", ownerLink: link(3, 3))
                #expect(supported)
            } catch let error as AgentSessionAttachError {
                #expect(!supported && error.code == AgentSessionAttachClient.startUnsupported)
            }
            await client.close()
        }
        let writes = daemon.frames.filter { $0["cmd"] as? String == "agent-session-credentials" }
        #expect(writes.count == (supported ? 2 : 0))
        #expect(writes.allSatisfy { $0["session"] as? String == "durable-chat" })
    }

    @Test(arguments: [false, true])
    func chatGPTRefreshUsesTheGuestWireVersion(supportsBoundCredentials: Bool) async throws {
        var capabilities = ["agent-session-attach-v1", "agent-session-start-v1",
                            DaemonCapability.agentSessionStartVMKind.rawValue,
                            AgentSessionAttachClient.startCredentialsCapability, AgentSessionAttachClient.startCodexCredentialsCapability]
        if supportsBoundCredentials { capabilities.append(AgentSessionAttachClient.boundCredentialsCapability) }
        let daemon = try PresenceDaemon(capabilities: capabilities)
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        let token = ["CMUX_CHATGPT_ACCESS_TOKEN": "fixture"]
        // The recording daemon acknowledges frames but does not create a real session.
        _ = try? await client.start(cwd: "/w", harness: "codex", ownerLink: link(3, 3), credentials: token)
        await client.close()
        let refresher = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try await refresher.updateCredentials(token, sessionID: "durable-chat", ownerLink: link(3, 3))
        await refresher.close()
        let start = try #require(daemon.frames.first { $0["cmd"] as? String == "agent-session-start" })
        #expect((start["credentials"] as? [String: Any])?["env"] as? [String: String] == token)
        let refresh = try #require(daemon.frames.first { $0["cmd"] as? String == "agent-session-credentials" })
        #expect(refresh["env"] as? [String: String] == token)
        #expect(refresh["vm_kind"] as? String == "owner")
        #expect(refresh["session"] as? String == (supportsBoundCredentials ? "durable-chat" : nil))
    }

    @Test(arguments: ["ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"])
    func aSavedClaudeTokenNeverGoesToAnUnboundPrewarm(variable: String) async throws {
        let daemon = try PresenceDaemon(capabilities: [
            "agent-session-attach-v1", "agent-session-start-v1", AgentSessionAttachClient.prewarmCapability,
            DaemonCapability.agentSessionStartVMKind.rawValue, AgentSessionAttachClient.startCredentialsCapability,
            AgentSessionAttachClient.boundCredentialsCapability, "agent-session-credential-reattach-v1",
        ])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        #expect(try await !client.prewarm(cwd: "/w", harness: "claude", ownerLink: link(3, 3),
                                          credentials: [variable: "sk-ant-oat-fixture"]))
        await client.close()
        #expect(!daemon.frames.contains { $0["cmd"] as? String == "agent-session-prewarm" })
    }

    /// A new Cloud machine's first start (or a down machine that reconnects on use): its link was
    /// not up yet, or came up again, while the start connected. The answer is taken again around
    /// the connection that is now live, instead of refusing the start the next try would allow.
    @Test func aStartWhoseLinkCameUpWhileConnectingAsksAgainOnTheLiveLink() async throws {
        let vmKind = [DaemonCapability.agentSessionStartVMKind.rawValue]
        for answers in [link(nil, 3, 3, 3), link(3, 4, 4, 4), link(nil, nil, 5, 5)] {
            let started = try await start(serving: vmKind, ownerLink: answers)
            // The fake daemon answers the start with no session; only that it went out counts here.
            #expect(started.refusal != "agent_session.host_unverified")
            #expect(started.frame?["vm_kind"] as? String == "owner")
        }

        // The answer that counts brackets the making of the connection the start goes on: the
        // connection made before it was read is dropped, and a new one is made inside it.
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-start-v1"] + vmKind)
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try? await client.start(cwd: "/w", harness: nil, ownerLink: link(nil, 3, 3, 3))
        await client.close()
        #expect(daemon.frames.filter { $0["cmd"] as? String == "identify" }.count == 2)
        #expect(daemon.frames.contains { $0["cmd"] as? String == "agent-session-start" })

        // Asked again a bounded number of times: a link that never settles on one owner answer
        // starts nothing.
        let flapping = try await start(serving: vmKind, ownerLink: link(1, 2, 3, 4, 5, 6, 7, 8))
        #expect(flapping.refusal == "agent_session.host_unverified")
        #expect(flapping.frame == nil)

        // Folder trust takes the same rule.
        let trusted = try await trust(serving: [DaemonCapability.agentSessionTrustVMKind.rawValue], ownerLink: link(nil, 3, 3, 3))
        #expect(trusted.refusal == nil)
        #expect(trusted.frame?["vm_kind"] as? String == "owner")
    }

    /// A connection made before the first owner read never carries the owner word: an earlier
    /// call's connection is retired and a new one made inside the reads. A client with an
    /// attachment keeps its connection, is refused, and its attachment is not told it ended.
    @Test func anOwnerWordGoesOnlyOnAConnectionMadeInsideTheReads() async throws {
        let caps = ["agent-session-attach-v1", "agent-session-start-v1", "agent-session-trust-v1",
                    DaemonCapability.agentSessionStartVMKind.rawValue]
        let daemon = try PresenceDaemon(capabilities: caps)
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        _ = try await client.trust(cwd: "/w", level: nil)
        _ = try? await client.start(cwd: "/w", harness: nil, ownerLink: link(3, 3, 3, 3))
        await client.close()
        #expect(daemon.frames.filter { $0["cmd"] as? String == "identify" }.count == 2)
        let sent = daemon.frames.first { $0["cmd"] as? String == "agent-session-start" }
        #expect(sent?["vm_kind"] as? String == "owner")

        let attachedDaemon = try PresenceDaemon(capabilities: caps)
        defer { attachedDaemon.stop() }
        let attached = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: attachedDaemon.path) }
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        _ = try await attached.attach(afterSeq: nil, beforeSeq: nil, limit: nil, kinds: nil) { name, _ in
            events.withLock { $0.append(name) }
        }
        await #expect(throws: AgentSessionAttachError.self) {
            _ = try await attached.start(cwd: "/w", harness: nil, ownerLink: link(nil, 3, 3, 3))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!events.withLock { $0 }.contains("agent-session-closed"))
        #expect(!attachedDaemon.frames.contains { $0["cmd"] as? String == "agent-session-start" })
        await attached.close()
    }

    /// The connection the owner answer was checked for ends right after the last check: the start
    /// fails, and never goes out over a new connection (another daemon, other capabilities).
    @Test func aStartNeverReconnectsAfterTheOwnerCheck() async throws {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-start-v1",
                                                       DaemonCapability.agentSessionStartVMKind.rawValue])
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        let reads = Answers([3])
        let ownerLink: AgentSessionAttachClient.OwnerLink = {
            if let first = await reads.next() { return first }
            // The second read, after the connection: end it, and give the client time to see so.
            daemon.dropClients()
            try? await Task.sleep(for: .milliseconds(300))
            return 3
        }
        await #expect(throws: AgentSessionAttachError.self) {
            _ = try await client.start(cwd: "/w", harness: nil, ownerLink: ownerLink)
        }
        await client.close()
        #expect(!daemon.frames.contains { $0["cmd"] as? String == "agent-session-start" }, "the start went out over a new connection")
        #expect(daemon.frames.filter { $0["cmd"] as? String == "identify" }.count == 1)
    }

    /// The client's refusal code, if any, and the `agent-session-trust` frame the daemon got.
    private func trust(serving extra: [String], ownerLink: AgentSessionAttachClient.OwnerLink?) async throws
        -> (refusal: String?, frame: [String: Any]?) {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-trust-v1"] + extra)
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        var refusal: String?
        do { _ = try await client.trust(cwd: "/w", level: nil, ownerLink: ownerLink) } catch let error as AgentSessionAttachError {
            refusal = error.code
        }
        await client.close()
        return (refusal, daemon.frames.first { $0["cmd"] as? String == "agent-session-trust" })
    }

    /// Folder trust takes the start's rule, with its own capability.
    @Test func aCloudTrustCallGoesOutOnlyOnTheOwnerAnswerOfTheSameLink() async throws {
        let vmKind = [DaemonCapability.agentSessionTrustVMKind.rawValue]
        #expect(vmKind == ["agent-session-trust-vm-kind-v1"])
        let owned = try await trust(serving: vmKind, ownerLink: link(3, 3))
        #expect(owned.refusal == nil)
        #expect(owned.frame?["vm_kind"] as? String == "owner")
        for (extra, answers) in [(vmKind, link(3, 4)), (vmKind, link(nil, nil)), ([], link(nil, nil))] {
            let refused = try await trust(serving: extra, ownerLink: answers)
            #expect(refused.refusal == "agent_session.host_unverified")
            #expect(refused.frame == nil, "\(extra)")
        }
        let older = try await trust(serving: [], ownerLink: link(5, 5))
        #expect(older.frame != nil)
        #expect(older.frame?["vm_kind"] == nil)
        let plain = try await trust(serving: vmKind, ownerLink: nil)
        #expect(plain.frame != nil)
        #expect(plain.frame?["vm_kind"] == nil)
    }

    @Test func aMachineThatIsNotCloudNeedsNoAnswer() async throws {
        let plain = try await start(serving: [DaemonCapability.agentSessionStartVMKind.rawValue], ownerLink: nil)
        #expect(plain.frame != nil)
        #expect(plain.frame?["vm_kind"] == nil)
    }
}
