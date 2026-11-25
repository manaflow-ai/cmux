@testable import CmuxNextHistory
import Foundation
import Testing

/// Go Back One Session (history.md 4.2d): the agent chats' own trail, which
/// `LocationTrailService` feeds only settled chats, every chat its own step.
struct GoBackOneSessionTests {
    static func chat(_ tab: String, workspace: String = "one", window: String = "w1") -> HistoryLocation {
        HistoryLocation(key: .init(machine: "m", tab: tab), window: window, workspace: workspace, pane: "p-\(tab)",
                        content: .other, title: tab)
    }

    static func terminal(_ tab: String) -> HistoryLocation {
        HistoryLocation(key: .init(machine: "m", tab: tab), window: "w1", workspace: "one", pane: "p-\(tab)",
                        content: .terminal, title: tab)
    }

    /// What the service does on each settle: only chats are steps.
    static func visit(_ places: [HistoryLocation], chats: Set<String>, into trail: inout LocationTrail, from start: Int = 0) {
        for (step, place) in places.enumerated() where chats.contains(place.key.tab) {
            trail.record(place, at: Date(timeIntervalSince1970: TimeInterval((start + step) * 10)))
        }
    }

    @Test func eachPressStepsOneChatFurtherBackAcrossWorkspacesAndWindows() throws {
        var sessions = LocationTrail()
        let places = [Self.chat("a"), Self.terminal("t"), Self.chat("b", workspace: "two"), Self.chat("c", window: "w2")]
        Self.visit(places, chats: ["a", "b", "c"], into: &sessions)
        #expect(sessions.entries.map(\.location.title) == ["a", "b", "c"], "the terminal is not a session step")
        let back1 = sessions.back()
        #expect(try #require(back1).location.title == "b")
        // The chat it focuses settles: absorbed, not a new step.
        let recorded2 = sessions.record(Self.chat("b", workspace: "two"), at: Date(timeIntervalSince1970: 100))
        #expect(!recorded2)
        let back3 = sessions.back()
        #expect(try #require(back3).location.title == "a")
        #expect(sessions.back() == nil, "no earlier session: the action refuses quietly")
    }

    @Test func twoChatsInOneWorkspaceAreTwoSteps() throws {
        var sessions = LocationTrail()
        Self.visit([Self.chat("a"), Self.chat("b")], chats: ["a", "b"], into: &sessions)
        let back4 = sessions.back()
        #expect(try #require(back4).location.title == "a")
    }

    @Test func aClosedOrEndedChatIsSkippedNotDropped() throws {
        var sessions = LocationTrail()
        Self.visit([Self.chat("a"), Self.chat("b"), Self.chat("c")], chats: ["a", "b", "c"], into: &sessions)
        let open: Set<String> = ["a", "c"]
        #expect(try #require(sessions.back { open.contains($0.key.tab) }).location.title == "a")
        #expect(sessions.entries.count == 3)
    }

    @Test func openingAnotherChatAfterGoingBackDropsTheLaterSteps() throws {
        var sessions = LocationTrail()
        Self.visit([Self.chat("a"), Self.chat("b"), Self.chat("c")], chats: ["a", "b", "c"], into: &sessions)
        let back5 = sessions.back()
        #expect(try #require(back5).location.title == "b")
        sessions.record(Self.chat("b"), at: Date(timeIntervalSince1970: 100))
        sessions.record(Self.chat("d"), at: Date(timeIntervalSince1970: 200))
        #expect(sessions.entries.map(\.location.title) == ["a", "b", "d"])
        let back6 = sessions.back()
        #expect(try #require(back6).location.title == "b")
    }
}
