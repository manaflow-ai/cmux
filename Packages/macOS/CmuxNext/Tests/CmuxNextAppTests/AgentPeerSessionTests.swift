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

    @Test func aPeersNameOrHarnessIdNeverAnswersForThisMacButItsMirroredIdStillOpens() {
        #expect(Self.lanes.localSession("peer-harness") == .asGiven)
        #expect(Self.lanes.localSession("01a16b00") == .session("01a16b00"))
    }

    @Test func anIdOrNameNothingGoesByOpensAsGiven() {
        // A chat that just started, a fixed-id session or one acpmux keeps without a lane.
        #expect(Self.lanes.localSession("01a1ffff-0000-7000-8000-000000000000") == .asGiven)
        #expect(Self.lanes.localSession("trigger_lane-1") == .asGiven)
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

/// `AgentLaneStore.tabSession` / `localSessionID`: the session and host `agent.openSessionTab` and
/// `agent.openSessionWorkspace` bind their tab to, and the refusal the caller reads when the given
/// session names more than one chat or no chat of a peer.
@MainActor
struct AgentSessionOpenTargetTests {
    static let localID = AgentLocalSessionTests.live

    static func store(live: Bool = true, extra: [AgentActivityLane] = []) -> AgentLaneStore {
        let store = AgentLaneStore()
        let all = AgentLocalSessionTests.lanes + AgentPeerSessionTests.lanes + extra
        store.lanes = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        store.live = live
        return store
    }

    /// The refusal `body` throws, nil when it throws none (any other error fails the test).
    static func refusal(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let refusal as AgentSessionOpenRefusal {
            return refusal.description
        } catch {
            Issue.record("not a refusal: \(error)")
            return nil
        }
    }

    @Test func thisMacsChatNamedByItsHarnessIdOrNameOpensAcpmuxsId() throws {
        let store = Self.store()
        for host in [nil, "this-mac"] {
            #expect(try store.localSessionID("cloud-demo", host: host, localHost: "this-mac") == Self.localID)
            let target = try store.tabSession("01a18641-9a05-7c33-8cfd-055af5d4f02a", host: host, localHost: "this-mac")
            #expect(target.session == Self.localID && target.host == host)
        }
    }

    /// Before the lane watch has every session, and for a host that is not this Mac, a name opens as given.
    @Test func beforeTheWatchIsLiveOrOnAnotherHostTheSessionOpensAsGiven() throws {
        #expect(try Self.store(live: false).localSessionID("cloud-demo", host: nil, localHost: "this-mac") == "cloud-demo")
        #expect(try Self.store().localSessionID("cloud-demo", host: "chief:0001", localHost: "this-mac") == "cloud-demo")
        let chief = try Self.store().tabSession("cloud-demo", host: "chief:0001", localHost: "this-mac")
        #expect(chief.session == "cloud-demo" && chief.host == "chief:0001")
    }

    @Test func aNameTwoOfThisMacsChatsGoByIsRefused() {
        let twin = AgentActivityLane(id: "codex-1", name: "codex/cloud-demo", title: "Twin", peer: nil, parent: nil,
                                     state: .idle, since: nil, error: nil, shortName: "cloud-demo")
        let store = Self.store(extra: [twin])
        let refusal = Self.refusal { _ = try store.localSessionID("cloud-demo", host: nil, localHost: "this-mac") }
        #expect(refusal?.contains("cloud-demo") == true)
        #expect(Self.refusal { _ = try store.tabSession("cloud-demo", host: nil, localHost: "this-mac") } == refusal)
    }

    @Test func aPeersChatOpensAsTheSessionThisMacMirrorsWithNoHost() throws {
        let target = try Self.store().tabSession("cx3-s10-dots", host: "cmux16", localHost: "this-mac")
        #expect(target.session == "01a16a4d" && target.host == nil)
    }

    @Test func aPeerWithNoChatOrTwoChatsOfThatNameIsRefused() {
        let unknown = Self.refusal { _ = try Self.store().tabSession("no-such-chat", host: "cmux16", localHost: "this-mac") }
        #expect(unknown?.contains("cmux16") == true && unknown?.contains("no-such-chat") == true)
        let twin = AgentActivityLane(id: "01a16a4e", name: "cmux16/cx3-s10-dots", title: "Dots 2", peer: "cmux16", parent: nil,
                                     state: .working, since: nil, error: nil)
        let ambiguous = Self.refusal { _ = try Self.store(extra: [twin]).tabSession("cx3-s10-dots", host: "cmux16", localHost: "this-mac") }
        #expect(ambiguous?.contains("cx3-s10-dots") == true && ambiguous != unknown)
    }

    /// A host this Mac mirrors no chat of keeps its host: the tab's host check refuses it with its own reason.
    @Test func aHostThatIsNoPeerStaysAsGiven() throws {
        let target = try Self.store().tabSession("anything", host: "session-host-a", localHost: "this-mac")
        #expect(target.session == "anything" && target.host == "session-host-a")
    }
}
