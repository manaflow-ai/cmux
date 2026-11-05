import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Which tab opening an existing chat adopts the prewarmed New Tab page, and when that page may
/// serve one (CmuxNextApp's SpareSessionAdoptionTests drive the tab store end to end).
@Suite
struct AgentPaneSpareAdoptionTests {
    /// HQ#5914 finding 1, review of #27759: a spare whose client is still connecting is not taken
    /// for an existing chat (the open would wait behind its chat list), nor in Low Power Mode or
    /// at serious thermal state (each open would make another page).
    @Test func whichSpareServesAChat() {
        func serves(handshake: Bool = true, painted: Bool = true, clientReady: Bool = true, lowPower: Bool = false,
                    thermal: ProcessInfo.ThermalState = .nominal) -> Bool {
            AgentPaneSpareReadiness(handshake: handshake, painted: painted, clientReady: clientReady,
                                    lowPower: lowPower, thermal: thermal).servesChat
        }
        #expect(serves())
        #expect(serves(thermal: .fair))
        #expect(!serves(handshake: false))
        #expect(!serves(painted: false))
        #expect(!serves(clientReady: false))
        #expect(!serves(lowPower: true))
        #expect(!serves(thermal: .serious))
        #expect(!serves(thermal: .critical))
    }

    /// Only a chat of this Mac's acpmux with a session, and nothing its own handshake must carry.
    @Test func theDecision() {
        func adopts(thisMac: Bool = true, session: String? = "s", newTabPage: Bool = false,
                    seeded: Bool = false, wake: Bool = false, chief: Bool = false) -> String? {
            AgentPaneSpareAdoption(thisMac: thisMac, session: session, newTabPage: newTabPage, seeded: seeded, wake: wake)
                .adopted(chiefKeeps: { _ in chief })
        }
        #expect(adopts() == "s")
        // Another machine's chat, or a Chief home's (the App's `AgentPaneHostKind` .remote, .chief).
        #expect(adopts(thisMac: false) == nil)
        #expect(adopts(session: nil) == nil)
        #expect(adopts(session: "") == nil)
        #expect(adopts(newTabPage: true) == nil)
        #expect(adopts(seeded: true) == nil)
        #expect(adopts(wake: true) == nil)
        #expect(adopts(chief: true) == nil)
    }
}
