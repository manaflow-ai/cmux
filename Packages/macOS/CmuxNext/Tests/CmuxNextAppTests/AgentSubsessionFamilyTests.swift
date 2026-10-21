import CmuxNextBridge
import Testing

/// acpmux's sub-session links (`startedBy`) as the app mirrors them: a chat's page may open only
/// the sessions of its own family (`chat.offer.open`).
@MainActor
struct AgentSubsessionFamilyTests {
    @Test func theLinkComesFromASummaryWithStartedBy() {
        #expect(AgentTurnStateStore.startedBy(summary: ["sessionId": "c1", "startedBy": " root "]) == "root")
        #expect(AgentTurnStateStore.startedBy(summary: ["sessionId": "root"]) == nil, "a root session has no parent")
        #expect(AgentTurnStateStore.startedBy(summary: ["sessionId": "x", "startedBy": "x"]) == nil, "a session never starts itself")
        let links = AgentTurnStateStore.startedBy(["sessions": [["sessionId": "c1", "startedBy": "root"], ["sessionId": "root"]]])
        #expect(links == ["c1": "root"])
    }

    @Test func aChatsFamilyIsItsSubsessionsAtAnyDepthAndItsParent() {
        let turns = AgentTurnStateStore()
        turns.setStartedBy("root", session: "a")
        turns.setStartedBy("a", session: "a1")
        turns.setStartedBy("elsewhere", session: "z")
        #expect(turns.isFamily("a", of: "root"))
        #expect(turns.isFamily("a1", of: "root"), "a grandchild")
        #expect(turns.isFamily("root", of: "a"), "the parent")
        #expect(!turns.isFamily("root", of: "a1"), "a grandparent is not offered")
        #expect(!turns.isFamily("z", of: "root"), "another chat's sub-session")
        #expect(!turns.isFamily("root", of: "root"), "never the chat itself")
    }

    @Test func aPageReplacesItsWatchsLinksAndAPurgeDropsOne() {
        let turns = AgentTurnStateStore()
        turns.replaceStartedBy(["a": "root", "b": "root"])
        #expect(turns.isFamily("b", of: "root"))
        turns.setStartedBy(nil, session: "a")
        #expect(!turns.isFamily("a", of: "root"), "purged")
        turns.replaceStartedBy([:])
        #expect(!turns.isFamily("b", of: "root"), "gone from the page")
        // Another watch's links stay.
        turns.setStartedBy("chief-root", session: "c", source: "chief:home")
        turns.replaceStartedBy([:])
        #expect(turns.isFamily("c", of: "chief-root"))
    }

    @Test func aCycleInBadDataEnds() {
        let turns = AgentTurnStateStore()
        turns.setStartedBy("b", session: "a")
        turns.setStartedBy("a", session: "b")
        #expect(!turns.isFamily("a", of: "c"))
    }
}
