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
            #expect(Self.lanes.peerSession(name, on: "cmux16") == .session("01a16a4d"))
        }
    }

    @Test func aNameOnlyMatchesOnItsOwnPeerNeverThisMacsOrAnothers() {
        #expect(Self.lanes.peerSession("nx-sidebar", on: "huge-blue") == .session("01a16b00"))
        #expect(Self.lanes.peerSession("nx-sidebar", on: "cmux16") == .unknownSession)
    }

    /// acpmux names can repeat: a repeated name is refused, never an arbitrary pick; its id still opens it.
    @Test func aRepeatedNameIsAmbiguousButItsIdStillOpens() {
        let twice = Self.lanes + [AgentActivityLane(id: "01a16a4e", name: "cmux16/cx3-s10-dots", title: "Dots 2", peer: "cmux16", parent: nil,
                                                    state: .working, since: nil, error: nil)]
        #expect(twice.peerSession("cx3-s10-dots", on: "cmux16") == .ambiguous)
        #expect(twice.peerSession("cmux16/01a16a4e", on: "cmux16") == .session("01a16a4e"))
    }

    @Test func aHostWithNoMirroredChatsIsNotAPeer() {
        #expect(Self.lanes.peerSession("anything", on: "big-red") == .notAPeer)
        #expect(Self.lanes.peerSession("anything", on: "chief:home") == .notAPeer)
    }
}
