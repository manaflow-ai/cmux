@testable import CmuxNextAgentLanes
import CmuxNextBridge
import Foundation
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

    /// A chat its agent made with `acpmux new` carries `spawnedBy` only; the tray and the Inspector
    /// list it as started, so a click on it must open it, not be refused.
    @Test func aSpawnedChatIsFamilyToo() {
        #expect(AgentTurnStateStore.startedBy(summary: ["sessionId": "lane", "spawnedBy": "coord"]) == "coord")
        #expect(AgentTurnStateStore.startedBy(summary: ["sessionId": "c", "startedBy": "a", "spawnedBy": "b"]) == "a",
                "the sub-session link wins")
        #expect(AgentTurnStateStore.startedBy(summary: ["sessionId": "c", "startedBy": " ", "spawnedBy": "b"]) == "b")
        #expect(AgentTurnStateStore.startedBy(summary: ["sessionId": "x", "spawnedBy": "x"]) == nil)
        let turns = AgentTurnStateStore()
        turns.replaceStartedBy(AgentTurnStateStore.startedBy(["sessions": [["sessionId": "lane", "spawnedBy": "coord"]]]))
        #expect(turns.isFamily("lane", of: "coord"))
    }

    /// The watch's lines carry the links: its page, a change, and none for a purge.
    @Test func theFeedReadsStartedByFromItsPageAndItsChanges() {
        func message(_ json: String) -> AgentTurnStateFeed.Message? { AgentTurnStateFeed.Message(line: Data(json.utf8)) }
        let page = message(#"{"id":2,"result":{"sessions":[{"sessionId":"c1","startedBy":"root"},{"sessionId":"root"}]}}"#)
        guard case .page(_, _, _, _, _, _, _, let links) = page else { Issue.record("not a page: \(String(describing: page))"); return }
        #expect(links == ["c1": "root"])
        let change = message(#"{"method":"_acpmux/session_changed","params":{"sessionId":"c1","session":{"sessionId":"c1","startedBy":"root"}}}"#)
        guard case .change(let session, _, _, _, _, _, _, _, let parent, _) = change else { Issue.record("not a change: \(String(describing: change))"); return }
        #expect(session == "c1")
        #expect(parent == "root")
        let purge = message(#"{"method":"_acpmux/session_changed","params":{"sessionId":"c1","kind":"purged"}}"#)
        guard case .change(_, _, _, _, _, _, _, _, let purged, _) = purge else { Issue.record("not a change: \(String(describing: purge))"); return }
        #expect(purged == nil, "a purged session keeps no parent")
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
        // Inside the cycle each is the other's parent: the walk ends and answers yes.
        #expect(turns.isFamily("a", of: "b"))
        #expect(turns.isFamily("b", of: "a"))
    }
}
