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

/// `agent.openSessionTab` / `agent.openSessionWorkspace` on this Mac: a chat named by its harness's
/// session id (`acpmux ls --json`'s `agentSessionId`) or its name opens as acpmux's id, so the tab
/// never records an id the chat pane cannot find ("Reconnecting…" forever, Leo 2026-11-05).
struct AgentLocalSessionTests {
    static let lanes = [
        AgentActivityLane(id: "01a18641-99db-7622-a8bc-496d43d639ca", name: "claude-sr2/cloud-demo", title: "cloud-demo", peer: nil,
                          parent: nil, state: .idle, since: nil, error: nil,
                          agentSession: "01a18641-9a05-7c33-8cfd-055af5d4f02a", shortName: "cloud-demo"),
        AgentActivityLane(id: "01a16b00", name: "huge-blue/cloud-demo", title: "Peer", peer: "huge-blue", parent: nil, state: .idle,
                          since: nil, error: nil, agentSession: "peer-harness", shortName: "cloud-demo"),
    ]
    static let live = "01a18641-99db-7622-a8bc-496d43d639ca"

    @Test func theHarnessSessionIdTheNameOrTheShortNameOpensAcpmuxsId() {
        for given in ["01a18641-9a05-7c33-8cfd-055af5d4f02a", "claude-sr2/cloud-demo", "cloud-demo", Self.live] {
            #expect(Self.lanes.localSession(given) == .session(Self.live))
        }
    }

    @Test func aPeersChatNeverAnswersForThisMac() {
        #expect(Self.lanes.localSession("peer-harness") == .unknown)
        #expect(Self.lanes.localSession("01a16b00") == .unknown)
    }

    @Test func anUnknownSessionIdOpensAsGivenAndUnknownTextIsRefused() {
        #expect(Self.lanes.localSession("01a1ffff-0000-7000-8000-000000000000") == .asGiven)
        #expect(Self.lanes.localSession("no-such-lane") == .unknown)
    }

    @Test func aNameTwoChatsGoByIsAmbiguous() {
        let twice = Self.lanes + [AgentActivityLane(id: "codex-1", name: "codex/cloud-demo", title: "Twin", peer: nil, parent: nil,
                                                    state: .idle, since: nil, error: nil, shortName: "cloud-demo")]
        #expect(twice.localSession("cloud-demo") == .ambiguous)
        #expect(twice.localSession("01a18641-9a05-7c33-8cfd-055af5d4f02a") == .session(Self.live))
    }

    @Test func aSummaryCarriesTheHarnessSessionIdAndShortName() throws {
        let lane = try #require(AgentActivityLane.of(summary: [
            "sessionId": Self.live, "name": "claude-sr2/cloud-demo", "shortName": "cloud-demo",
            "agentSessionId": "01a18641-9a05-7c33-8cfd-055af5d4f02a", "lane": ["state": "idle"],
        ]))
        #expect(lane.agentSession == "01a18641-9a05-7c33-8cfd-055af5d4f02a")
        #expect(lane.shortName == "cloud-demo")
    }
}
