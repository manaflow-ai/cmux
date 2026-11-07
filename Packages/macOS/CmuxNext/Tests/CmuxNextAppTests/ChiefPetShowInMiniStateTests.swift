import CmuxNextAgentActivity
@testable import CmuxNextChiefPetWiring
import CmuxNextFloating
import Testing

/// The mini pointed at a chat (Show in Mini) draws that chat's lane as acpmux decided it.
struct ChiefPetShowInMiniStateTests {
    @Test func aChatsLaneIsThePetsState() {
        #expect(ChiefPetMini.state(AgentActivityLane.State.working) == .working)
        #expect(ChiefPetMini.state(AgentActivityLane.State.input) == .waiting, "needs you")
        #expect(ChiefPetMini.state(AgentActivityLane.State.failed) == .error)
        #expect(ChiefPetMini.state(AgentActivityLane.State.lost) == .error)
        #expect(ChiefPetMini.state(AgentActivityLane.State.idle) == .idle)
        #expect(ChiefPetMini.state(AgentActivityLane.State?.none) == .idle, "no lane yet: idle, never working")
    }
}
