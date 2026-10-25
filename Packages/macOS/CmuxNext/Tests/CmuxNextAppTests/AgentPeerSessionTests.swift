import CmuxNextAgentActivity
import CmuxNextAgentLanes
import Testing

/// `agent.openSessionTab {session, host: "<peer>"}`: a peer's chat opens as the session this Mac's
/// acpmux mirrors (cx-k21v keeps every tab bound here), named by id, qualified id or name.
struct AgentPeerSessionTests {
    static let lanes = [
        AgentActivityLane(id: "01a16a4d", name: "cmux16/cx3-s10-dots", title: "Dots", peer: "cmux16", parent: nil, state: .idle, since: nil, error: nil),
        AgentActivityLane(id: "01a16b00", name: "huge-blue/nx-sidebar", title: "Rows", peer: "huge-blue", parent: nil, state: .working, since: nil, error: nil),
        AgentActivityLane(id: "local-1", name: "nx-sidebar", title: "Local", peer: nil, parent: nil, state: .idle, since: nil, error: nil),
    ]

    @Test func anIdQualifiedIdOrNameNamesThePeersMirroredSession() {
        for name in ["01a16a4d", "cmux16/01a16a4d", "cmux16/cx3-s10-dots", "cx3-s10-dots"] {
            #expect(AgentPeerSession.resolve(name, peer: "cmux16", lanes: Self.lanes) == .session("01a16a4d"))
        }
    }

    @Test func aNameOnlyMatchesOnItsOwnPeerNeverThisMacsOrAnothers() {
        #expect(AgentPeerSession.resolve("nx-sidebar", peer: "huge-blue", lanes: Self.lanes) == .session("01a16b00"))
        #expect(AgentPeerSession.resolve("nx-sidebar", peer: "cmux16", lanes: Self.lanes) == .unknownSession)
    }

    /// acpmux names can repeat: a repeated name is refused, never an arbitrary pick; its id still opens it.
    @Test func aRepeatedNameIsAmbiguousButItsIdStillOpens() {
        let twice = Self.lanes + [AgentActivityLane(id: "01a16a4e", name: "cmux16/cx3-s10-dots", title: "Dots 2", peer: "cmux16", parent: nil,
                                                    state: .working, since: nil, error: nil)]
        #expect(AgentPeerSession.resolve("cx3-s10-dots", peer: "cmux16", lanes: twice) == .ambiguous)
        #expect(AgentPeerSession.resolve("cmux16/01a16a4e", peer: "cmux16", lanes: twice) == .session("01a16a4e"))
    }

    @Test func aHostWithNoMirroredChatsIsNotAPeer() {
        #expect(AgentPeerSession.resolve("anything", peer: "big-red", lanes: Self.lanes) == .notAPeer)
        #expect(AgentPeerSession.resolve("anything", peer: "chief:home", lanes: Self.lanes) == .notAPeer)
    }
}
