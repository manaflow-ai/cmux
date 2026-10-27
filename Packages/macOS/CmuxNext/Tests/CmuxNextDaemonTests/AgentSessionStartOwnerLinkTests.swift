import Foundation
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

    @Test func aMachineThatIsNotCloudNeedsNoAnswer() async throws {
        let plain = try await start(serving: [DaemonCapability.agentSessionStartVMKind.rawValue], ownerLink: nil)
        #expect(plain.frame != nil)
        #expect(plain.frame?["vm_kind"] == nil)
    }
}
