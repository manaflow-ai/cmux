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
    private func start(serving extra: [String], ownerLink: AgentSessionAttachClient.OwnerLink?) async throws
        -> (refusal: String?, frame: [String: Any]?) {
        let daemon = try PresenceDaemon(capabilities: ["agent-session-attach-v1", "agent-session-start-v1"] + extra)
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: daemon.path) }
        var refusal: String?
        do { _ = try await client.start(cwd: "/w", harness: nil, ownerLink: ownerLink) } catch let error as AgentSessionAttachError {
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
