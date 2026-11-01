import CmuxNextDaemon
import CmuxNextSettings
import Observation
import Testing
@testable import CmuxNextAgentPane

/// The composer strip's machine dot (`machineLink`, the sidebar header's same word) and the
/// reconnect a chat's use of a down machine runs (Leo, 2026-10-28: "as if you were working on your
/// own computer, but now it's remote").
@MainActor @Suite(.serialized)
struct AgentPaneMachineLinkTests {
    @Test func thePaneEventCarriesTheWord() {
        let state = AgentPaneMachineLink.State(machine: "m-1", link: "connecting", words: "Reconnecting…")
        #expect(AgentPaneMachineLink.event(state).kind == "machineLink")
        #expect(AgentPaneMachineLink.event(state).value == ["machine": "m-1", "link": "connecting", "words": "Reconnecting…"])
        #expect(AgentPaneMachineLink.event(nil).value == .null, "a chat on this Mac has no machine dot")
    }

    private struct Down: Error {}

    private actor Calls {
        var endpoint = 0
        var reconnect: [String] = []
        func tapEndpoint() -> Int { endpoint += 1; return endpoint }
        func tapReconnect(_ machine: String) { reconnect.append(machine) }
    }

    /// A connection to a down machine (its endpoint, its socket or its handshake failing) reconnects
    /// it once and goes on; a machine that does not come back fails as it did, and a connection
    /// that works never reconnects.
    @Test func aDownMachineReconnectsOnUse() async throws {
        let calls = Calls()
        let socket = DaemonEndpoint(socketPath: "/tmp/acpmux-test.sock")
        let comesBack = try await AgentSessionAttachClient.retrying({ _ in
            if await calls.tapEndpoint() == 1 { throw Down() }
            return socket
        }, reconnect: { await calls.tapReconnect("box"); return true })
        #expect(comesBack == socket)
        #expect(await calls.reconnect == ["box"])

        await #expect(throws: Down.self) {
            try await AgentSessionAttachClient.retrying({ _ throws -> DaemonEndpoint in throw Down() }, reconnect: { false })
        }

        let up = Calls()
        let fine = try await AgentSessionAttachClient.retrying({ _ in socket }, reconnect: { await up.tapReconnect("box"); return true })
        #expect(fine == socket)
        #expect(await up.reconnect.isEmpty)
    }

    @Observable @MainActor final class Machine {
        var use: AgentPaneMachineLink.Use
        init(_ use: AgentPaneMachineLink.Use) { self.use = use }
    }

    /// A down machine runs its header's Reconnect and the wait ends at its handshake; one on its
    /// way is only waited for; one a person must fix is never reconnected; the wait is bounded.
    @Test func theWaitEndsAtTheHandshake() async {
        let link = AgentPaneMachineLink()
        let machine = Machine(.down)
        var ran: [String] = []
        link.use = { _ in machine.use }
        // The handshake finishes after the reconnect returned, while the chat waits.
        link.reconnect = { id in ran.append(id); machine.use = .coming; Task { machine.use = .up } }
        #expect(await link.awaitLink("box"))
        #expect(ran == ["box"])

        machine.use = .stuck
        #expect(await link.awaitLink("box") == false)
        #expect(ran == ["box"], "sign-in or an update waits for a person")

        machine.use = .coming
        link.budget = .milliseconds(20)
        #expect(await link.awaitLink("box") == false, "a link that never comes back fails as it did")
        #expect(ran == ["box"], "a machine on its way is not reconnected again")

        // A reconnect that ends needing a person (a refused sign-in, a required update) fails the
        // send at once, not after the budget.
        link.budget = .seconds(30)
        machine.use = .down
        link.reconnect = { id in ran.append(id); machine.use = .coming; Task { machine.use = .stuck } }
        let refused = ContinuousClock.now
        #expect(await link.awaitLink("box") == false)
        #expect(ContinuousClock.now - refused < .seconds(5))
        #expect(ran == ["box", "box"])
        machine.use = .coming

        // A send cancelled while it waits stops waiting at once, well inside the budget.
        link.budget = .seconds(30)
        let started = ContinuousClock.now
        let send = Task { await link.awaitLink("box") }
        // Let it start waiting (both run on the main actor) before the cancel.
        for _ in 0..<10 { await Task.yield() }
        send.cancel()
        #expect(await send.value == false)
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
