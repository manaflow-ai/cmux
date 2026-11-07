import CmuxNextAgentActivity
@testable import CmuxNextChiefPetWiring
import CmuxNextFloating
import Foundation
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

    /// A peer's chat is sent to by its stable id as `HOST/ID`: a name can repeat on a peer (review F5).
    @MainActor @Test func aPeersChatIsSentToByItsId() throws {
        let lanes = AgentLaneStore()
        let summary: [String: Any] = ["sessionId": "abc123", "name": "huge-blue/coord", "peer": "huge-blue", "lane": ["state": "idle"]]
        lanes.set("abc123", try #require(AgentActivityLane.of(summary: summary)))
        let mini = ChiefPetMini(subject: ChiefPetSubject(defaults: UserDefaults(suiteName: "ChiefPetMiniPeer")!), uploads: ChiefAvatarUploads(folder: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
                                lanes: lanes, localHost: { "install:mac" }, settings: { nil }, pet: { nil }, acpmux: nil)
        #expect(mini.sendName(ChiefPetSubject.Chat(host: "huge-blue", session: "abc123")) == "huge-blue/abc123")
        #expect(mini.sendName(ChiefPetSubject.Chat(host: "install:mac", session: "local1")) == "local1")
        #expect(mini.sendName(ChiefPetSubject.Chat(host: "big-red", session: "abc123")) == "big-red/abc123", "the saved host, not the lane's peer")
    }
}
