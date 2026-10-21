import CmuxNextBridge
import CmuxNextDaemon
import Testing

/// acpmux's sub-session tree (`startedBy` links) as the app mirrors it: the sidebar nests a chat's
/// sub-sessions under its tab, and a chat's page may open only sessions of its own family.
@MainActor
struct AgentSubsessionTreeTests {
    static let host = "install:subsessions"

    static func store() -> AgentTurnStateStore {
        let turns = AgentTurnStateStore()
        turns.localHost = host
        return turns
    }

    static func ref(_ session: String, host: String = host) -> AgentSessionRef {
        AgentSessionRef(host: host, session: session)
    }

    @Test func factsComeFromASummaryWithStartedBy() {
        let facts = AgentSubsessionFacts.of(summary: ["sessionId": "c1", "startedBy": "root", "shortName": " tests ",
                                                      "depth": 2, "queued": 3, "unread": true, "createdAt": 42])
        #expect(facts == AgentSubsessionFacts(startedBy: "root", shortName: "tests", depth: 2, queued: 3, unread: true, createdAtMs: 42))
        #expect(AgentSubsessionFacts.of(summary: ["sessionId": "root"]) == nil, "a root session has no facts")
        #expect(AgentSubsessionFacts.of(summary: ["sessionId": "x", "startedBy": "x"]) == nil, "a session never starts itself")
        #expect(AgentSubsessionFacts.of(summary: ["sessionId": "c1", "startedBy": "root", "status": "closed"])?.closed == true)
        let all = AgentSubsessionFacts.all(["sessions": [["sessionId": "c1", "startedBy": "root"], ["sessionId": "root"]]])
        #expect(Array(all.keys) == ["c1"])
    }

    @Test func subsessionsListDepthFirstInStartOrder() {
        let turns = Self.store()
        turns.setSubsession(AgentSubsessionFacts(startedBy: "root", createdAtMs: 20), session: "b")
        turns.setSubsession(AgentSubsessionFacts(startedBy: "root", createdAtMs: 10), session: "a")
        turns.setSubsession(AgentSubsessionFacts(startedBy: "a", depth: 2, createdAtMs: 30), session: "a1")
        turns.setState(.working, session: "a1")
        let entries = turns.subsessions(of: Self.ref("root"))
        #expect(entries.map(\.session) == ["a", "a1", "b"])
        #expect(entries.map(\.depth) == [1, 2, 1])
        #expect(entries.first { $0.session == "a1" }?.state == .working)
        #expect(turns.subsessions(of: Self.ref("a")).map(\.session) == ["a1"])
    }

    @Test func aClosedSubsessionGivesItsPlaceToItsChildren() {
        let turns = Self.store()
        turns.setSubsession(AgentSubsessionFacts(startedBy: "root", closed: true), session: "a")
        turns.setSubsession(AgentSubsessionFacts(startedBy: "a", depth: 2), session: "a1")
        let entries = turns.subsessions(of: Self.ref("root"))
        #expect(entries.map(\.session) == ["a1"])
        #expect(entries.map(\.depth) == [1])
        #expect(turns.openSubsessionParents() == ["a1": "a"])
    }

    @Test func anotherMachinesChatListsNone() {
        let turns = Self.store()
        turns.setSubsession(AgentSubsessionFacts(startedBy: "root"), session: "a")
        #expect(turns.subsessions(of: Self.ref("root", host: "registry:other")).isEmpty)
    }

    @Test func reparentingAndPurgingMoveTheTree() {
        let turns = Self.store()
        turns.setSubsession(AgentSubsessionFacts(startedBy: "root"), session: "a")
        let revision = turns.familyRevision
        turns.setSubsession(AgentSubsessionFacts(startedBy: "other"), session: "a")
        #expect(turns.familyRevision != revision)
        #expect(turns.subsessions(of: Self.ref("root")).isEmpty)
        #expect(turns.subsessions(of: Self.ref("other")).map(\.session) == ["a"])
        turns.replaceSubsessions([:])
        #expect(turns.subsessions(of: Self.ref("other")).isEmpty)
    }

    @Test func aChatsFamilyIsItsSubsessionsAtAnyDepthAndItsParent() {
        let turns = Self.store()
        turns.setSubsession(AgentSubsessionFacts(startedBy: "root"), session: "a")
        turns.setSubsession(AgentSubsessionFacts(startedBy: "a", depth: 2), session: "a1")
        turns.setSubsession(AgentSubsessionFacts(startedBy: "elsewhere"), session: "z")
        #expect(turns.isFamily("a", of: "root"))
        #expect(turns.isFamily("a1", of: "root"), "a grandchild")
        #expect(turns.isFamily("root", of: "a"), "the parent")
        #expect(!turns.isFamily("root", of: "a1"), "a grandparent is not offered")
        #expect(!turns.isFamily("z", of: "root"), "another chat's sub-session")
        #expect(!turns.isFamily("root", of: "root"), "never the chat itself")
    }

    @Test func aCycleInBadDataEnds() {
        let turns = Self.store()
        turns.setSubsession(AgentSubsessionFacts(startedBy: "b"), session: "a")
        turns.setSubsession(AgentSubsessionFacts(startedBy: "a"), session: "b")
        #expect(!turns.isFamily("a", of: "c"))
        #expect(turns.subsessions(of: Self.ref("a")).map(\.session) == ["b"])
    }
}
