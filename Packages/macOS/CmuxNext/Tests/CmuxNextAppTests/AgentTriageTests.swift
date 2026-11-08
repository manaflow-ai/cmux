import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import Foundation
import Testing

/// Triage (wow idea 22): Ctrl-Cmd-; opens the chat that has waited longest, Ctrl-Cmd-Y answers the
/// waiting chat on screen and opens the next, and nothing unseen is ever answered.
@MainActor
struct AgentTriageTests {
    static func lane(_ id: String, waited minutes: Double?, state: AgentActivityLane.State = .input) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: nil, parent: nil, state: state,
                          since: minutes.map { Date(timeIntervalSinceNow: -$0 * 60) }, error: nil, project: "cmux")
    }

    static func chats(_ lanes: [AgentActivityLane]) -> AgentPriorityChats {
        let store = AgentLaneStore()
        store.lanes = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        return AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], checksFailing: { _ in false }, archive: { _, _ in })
    }

    /// Three waiting chats (b waited longest, then a, then c with no time) and one working chat.
    static let lanes = [lane("a", waited: 2), lane("b", waited: 9), lane("c", waited: nil), lane("busy", waited: 30, state: .working)]

    @Test func theQueueIsLongestWaitingFirst() {
        let waiting = Self.lanes.filter { $0.state == .input }
        #expect(AgentTriage.queue(waiting).map(\.id) == ["b", "a", "c"])
    }

    @Test func aPressGoesOnFromTheChatOnScreen() {
        let queue = AgentTriage.queue(Self.lanes.filter { $0.state == .input })
        // From anywhere else: the longest-waiting chat.
        #expect(AgentTriage.target(in: queue, after: nil)?.id == "b")
        #expect(AgentTriage.target(in: queue, after: "busy")?.id == "b")
        // From a waiting chat: the one queued after it, wrapping.
        #expect(AgentTriage.target(in: queue, after: "b")?.id == "a")
        #expect(AgentTriage.target(in: queue, after: "c")?.id == "b")
        // Alone in the queue: nowhere else to go.
        #expect(AgentTriage.target(in: [Self.lane("a", waited: 1)], after: "a") == nil)
        #expect(AgentTriage.target(in: [], after: nil) == nil)
    }

    @Test func nextOpensTheLongestWaitingChat() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var opened: [String] = []
        var shown: String?
        AgentTriage(chats: Self.chats(Self.lanes)).bind(into: registry, shown: { _ in
            shown.map { AgentTriage.Shown(session: $0) { _ in Issue.record("next never answers") } }
        }, open: { opened.append($0.id); shown = $0.id })
        for _ in 0..<4 { #expect(registry.perform(AgentTriage.next, invocation: ActionInvocation(origin: .user))) }
        #expect(opened == ["b", "a", "c", "b"])
    }

    @Test func answerAnswersTheWaitingChatOnScreenThenOpensTheNext() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var opened: [String] = []
        var answered: [(String, Bool)] = []
        var shown: String? = "a"
        AgentTriage(chats: Self.chats(Self.lanes)).bind(into: registry, shown: { _ in
            shown.map { session in AgentTriage.Shown(session: session) { answered.append((session, $0)) } }
        }, open: { opened.append($0.id); shown = $0.id })
        #expect(registry.perform(AgentTriage.answer, invocation: ActionInvocation(origin: .user)))
        #expect(answered.map(\.0) == ["a"])
        #expect(answered.first?.1 == true)
        #expect(opened == ["c"])
    }

    @Test func answerNeverAnswersAChatThatIsNotWaiting() {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var opened: [String] = []
        var answered: [String] = []
        // On screen: a working chat. The press opens the longest-waiting chat and answers nothing.
        AgentTriage(chats: Self.chats(Self.lanes)).bind(into: registry, shown: { _ in
            AgentTriage.Shown(session: "busy") { _ in answered.append("busy") }
        }, open: { opened.append($0.id) })
        #expect(registry.perform(AgentTriage.answer, invocation: ActionInvocation(origin: .user)))
        #expect(answered.isEmpty)
        #expect(opened == ["b"])
    }

    @Test func theActionsAreInTheCatalogWithTheirKeys() throws {
        let next = try #require(ActionCatalog.all.first { $0.id == AgentTriage.next })
        let answer = try #require(ActionCatalog.all.first { $0.id == AgentTriage.answer })
        #expect(next.defaultShortcut == Shortcut(";", modifiers: [.command, .control]))
        #expect(answer.defaultShortcut == Shortcut("y", modifiers: [.command, .control]))
        #expect(answer.isPersonOnly)
        #expect(!next.isPersonOnly)
    }
}
