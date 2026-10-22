@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextRemote
import Testing

/// Leo, 2026-10-21: an agent chat on another Mac (a Mac mini over Tailscale) that cannot be
/// reached read "acpmux did not answer in time", the same as a slow agent. Each way of not
/// reaching the machine is its own refusal that names the machine and what to fix, and a full
/// disk there is its own refusal, never a timeout.
@MainActor struct AgentRemoteReachTests {
    private let machine = "mini-1"

    private func message(_ error: any Error) throws -> String {
        let refusal = try #require(AgentRemoteStartRefusal.unreached(error, machine: machine), "not read as unreached: \(error)")
        #expect(refusal.code.hasPrefix(AgentRemoteStartRefusal.unreachedPrefix), "\(refusal.code)")
        #expect(refusal.userMessage.contains(machine), "the message does not name the machine: \(refusal.userMessage)")
        return refusal.userMessage
    }

    @Test func tailscaleOffOnTheHostDialSaysTurnTailscaleOn() throws {
        let text = try message(DaemonError.endpointBlocked(DaemonBridge.refusalMessage(code: "tailscale_off")))
        #expect(text.contains("Tailscale"), "\(text)")
        #expect(AgentRemoteStartRefusal.unreached(DaemonError.endpointBlocked(DaemonBridge.refusalMessage(code: "tailscale_off")), machine: machine)?.code
            == "agent_session.unreached.tailscale_off")
    }

    @Test func aNameTheTailnetDoesNotKnowSaysSignInOrCheckTheName() throws {
        let ssh = SSHLinkError.ssh(.unreachable("ssh: Could not resolve hostname mini-1: nodename nor servname provided, or not known"))
        let text = try message(ssh)
        #expect(text.contains("Tailscale"), "\(text)")
        #expect(AgentRemoteStartRefusal.unreached(ssh, machine: machine)?.code == "agent_session.unreached.name")
    }

    @Test func aPortThatRefusesSaysWhatToTurnOn() throws {
        let ssh = SSHLinkError.ssh(.unreachable("ssh: connect to host mini-1 port 22: Connection refused"))
        #expect(try message(ssh).contains("Remote Login"))
        let dial = DaemonError.endpointBlocked(DaemonBridge.refusalMessage(code: "not_serving"))
        #expect(try message(dial).contains("cmux host enable"))
    }

    @Test func noAnswerSaysAwakeAndTailscaleOnBoth() throws {
        let ssh = SSHLinkError.ssh(.unreachable("ssh: connect to host mini-1 port 22: Operation timed out"))
        let text = try message(ssh)
        #expect(text.contains("awake"), "\(text)")
        #expect(AgentRemoteStartRefusal.unreached(ssh, machine: machine)?.code == "agent_session.unreached.no_answer")
    }

    @Test func aDroppedConnectionIsUnreachedNotATimeout() throws {
        let lost = DaemonError.connectionClosed(reason: "eof")
        #expect(AgentRemoteStartRefusal.unreached(lost, machine: machine)?.code == "agent_session.unreached.lost")
        let text = try message(lost)
        #expect(!text.contains("did not answer in time"), "\(text)")
    }

    @Test func aRefusalFromTheMachineItselfIsNotUnreached() {
        let refused = DaemonError.command(cmd: "agent-session-prompt", message: "nope", code: "agent_session.refused")
        #expect(AgentRemoteStartRefusal.unreached(refused, machine: machine) == nil)
        #expect(AgentRemoteStartRefusal.unreached(SSHLinkError.ssh(.authFailed("Permission denied (publickey).")), machine: machine) == nil)
    }

    @Test func aFullDiskThereIsItsOwnRefusal() {
        let full = AgentRemoteStartRefusal(code: "agent_session.storage_full", machine: machine)
        #expect(full.userMessage.contains(machine))
        #expect(full.userMessage.localizedCaseInsensitiveContains("disk"), "\(full.userMessage)")
    }

    /// The pane's wire carries the class: a page call that cannot reach the machine fails with
    /// the unreached code and the sentence, never `remote.unsupported` and a Swift dump.
    @Test func theRemoteClientMapsAnUnreachedMachineToItsRefusal() async throws {
        let client = AgentTabRemoteClient(client: AgentSessionAttachClient(surface: 1, endpoint: { throw DaemonError.connectFailed(path: "/tmp/x.sock", errno: 61) }),
                                          mode: .attach, machine: machine)
        do {
            _ = try await client.mapped { throw SSHLinkError.ssh(.unreachable("ssh: connect to host mini-1 port 22: Operation timed out")) }
            Issue.record("no error")
        } catch let error as AgentSessionRemoteError {
            #expect(error.code == "agent_session.unreached.no_answer")
            #expect(error.message.contains(machine))
        }
        do {
            _ = try await client.mapped { throw AgentSessionAttachError(code: "agent_session.storage_full", message: "the disk on this machine is full") }
            Issue.record("no error")
        } catch let error as AgentSessionRemoteError {
            #expect(error.code == "agent_session.storage_full")
            #expect(error.message.contains(machine), "\(error.message)")
        }
    }
}
