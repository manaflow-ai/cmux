import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The menu bar's "Needs input: N" and Go to Next Agent Needing Input count and visit the same
/// targets (review of #30104): a terminal whose program waits (an OSC 7501 `blocked` record) is
/// one, as it was before the action, beside the agent chats at a question.
@MainActor
struct AgentNeedsInputJumpTests {
    /// A store with one terminal tab whose program status is `records`.
    static func store(records: String) throws -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_7","extra":{"program_status":\#(records)}}],"extra":{"state":{}}}}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        return store
    }

    static let blocked = #"[{"id":"","state":"blocked","kind":"permission","app":"terraform","title":"terraform apply","msg":"Apply 3 changes?","updated_seq":"2"}]"#

    static func chats(_ lanes: [AgentActivityLane] = []) -> AgentPriorityChats {
        let store = AgentLaneStore()
        store.lanes = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        return AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], checksFailing: { _ in false }, archive: { _, _ in })
    }

    @Test func aBlockedTerminalWithNoWaitingChatIsCountedAndVisited() throws {
        let store = try Self.store(records: Self.blocked)
        let tab = try #require(AgentNeedsInputJump.tabs(of: store).first)
        let chats = Self.chats()
        // The menu bar's count: one, so its row shows "Needs input: 1".
        let targets = AgentNeedsInputJump.targets(chats: chats, tabs: AgentNeedsInputJump.tabs(of: store))
        #expect(targets == [.tab(tab.id)])
        #expect(MenuBarMenuSpec().items(for: MenuBarMenuState(agentsNeedingInput: targets.count), isBound: { _ in true })
            .contains(.action("agent.jumpToNextNeedingInput", title: "Needs input: 1", symbol: "exclamationmark.bubble")))

        // The action reveals that terminal.
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var revealed: [String] = []
        var opened: [String] = []
        AgentNeedsInputJump(chats: chats, tabs: { AgentNeedsInputJump.tabs(of: store) })
            .bind(into: registry, open: { opened.append($0.id) }, reveal: { revealed.append($0) })
        #expect(registry.perform(AgentNeedsInputJump.action, invocation: ActionInvocation(origin: .user)))
        #expect(revealed == [tab.id])
        #expect(opened.isEmpty)
    }

    @Test func chatsComeFirstThenTerminalsAndNothingIsRefused() throws {
        let store = try Self.store(records: Self.blocked)
        let tab = try #require(AgentNeedsInputJump.tabs(of: store).first)
        let asks = AgentActivityLane(id: "asks", name: "asks", title: "asks", peer: nil, parent: nil, state: .input, since: Date(),
                                     error: nil, project: "cmux")
        let jump = AgentNeedsInputJump(chats: Self.chats([asks]), tabs: { AgentNeedsInputJump.tabs(of: store) })
        #expect(jump.next() == .chat(asks))
        #expect(jump.next() == .tab(tab.id))
        #expect(jump.next() == .chat(asks))

        let idle = try Self.store(records: "[]")
        let none = AgentNeedsInputJump(chats: Self.chats(), tabs: { AgentNeedsInputJump.tabs(of: idle) })
        #expect(none.next() == nil)
        #expect(AgentNeedsInputJump.targets(chats: Self.chats(), tabs: AgentNeedsInputJump.tabs(of: idle)).isEmpty)
    }
}
