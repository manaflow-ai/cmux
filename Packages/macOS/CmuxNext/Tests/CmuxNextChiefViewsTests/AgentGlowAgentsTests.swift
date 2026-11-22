import CmuxNextAgentActivity
import CmuxNextDesign
import Foundation
import Observation
import os
import Testing
@testable import CmuxNextChiefViews

/// `appearance.agentGlow` reads the agents: lanes that work or wait, on the machine they run on,
/// and nothing that changes with every step an agent takes.
@MainActor
@Suite struct AgentGlowAgentsTests {
    private static func lane(_ id: String, peer: String?, state: AgentActivityLane.State, step: String? = nil) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: peer, parent: nil, state: state, since: nil, error: nil, step: step)
    }

    @Test func lanesThatWorkOrWaitCountOnTheirMachine() {
        let lanes = AgentLaneStore()
        lanes.lanes = ["a": Self.lane("a", peer: nil, state: .input), "b": Self.lane("b", peer: "my-vm", state: .working),
                       "c": Self.lane("c", peer: "huge-blue", state: .idle)]
        let agents = BackdropAgentGlow.Agent.current(workspaces: [], machineName: { _ in nil }, localMachine: "this-mac", lanes: lanes)
        #expect(Set(agents) == [.init(machine: "this-mac", level: .needsYou), .init(machine: "my-vm", level: .working)])
    }

    /// A working agent changes its lane many times a second: a step must not wake the glow's
    /// reader, while starting to wait must.
    @Test func anAgentsStepDoesNotWakeTheReaderButWaitingDoes() {
        let lanes = AgentLaneStore()
        lanes.set("a", Self.lane("a", peer: nil, state: .working, step: "Reading"))
        let woke = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = BackdropAgentGlow.Agent.current(workspaces: [], machineName: { _ in nil }, localMachine: "m", lanes: lanes)
        } onChange: { woke.withLock { $0 = true } }
        lanes.set("a", Self.lane("a", peer: nil, state: .working, step: "Editing"))
        #expect(!woke.withLock { $0 })
        lanes.set("a", Self.lane("a", peer: nil, state: .input))
        #expect(woke.withLock { $0 })
    }
}
