import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextFocus
@testable import CmuxNextApp
import Testing

struct ChatColumnPlacementTests {
    enum Tab: Equatable, Sendable {
        case chat, newTab, terminal, browser, file, diff
    }

    @Test(arguments: [
        ([Tab.chat], true),
        ([Tab.chat, .newTab], true),
        ([Tab.chat, .newTab, .newTab], true),
        ([Tab.newTab, .chat], true),
        ([Tab.chat, .terminal], false),
        ([Tab.chat, .newTab, .terminal], false),
        ([Tab.chat, .chat], false),
        ([Tab.newTab], false),
        ([Tab.chat, .browser], false),
        ([Tab.chat, .file], false),
        ([Tab.chat, .diff], false),
        ([], false),
    ])
    func onlyNewTabPagesMayAccompanyALoneChat(tabs: [Tab], expected: Bool) {
        let chat = ChatColumnPlacement.loneChat(in: tabs, isChat: { $0 == .chat }, isNewTabPage: { $0 == .newTab })
        #expect((chat != nil) == expected)
    }

    @Test(arguments: [
        (Tab.chat, true),
        (Tab.newTab, true),
        (Tab.terminal, false),
        (Tab.browser, false),
        (Tab.file, false),
        (Tab.diff, false),
    ])
    func chatDockAcceptsChatsAndNewTabPages(tab: Tab, expected: Bool) {
        #expect(ChatDockRules.accepts(tab, isChat: { $0 == .chat }, isNewTabPage: { $0 == .newTab }) == expected)
    }

    @MainActor @Test func pagesMoveAfterDockPreparationInOrder() async {
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        focus.send(.topology(FocusTopology(workspace: "workspace", panes: [
            .init(id: "dock", tabs: [.init(id: "chat", kind: .agent)], selected: "chat"),
            .init(id: "strip", tabs: [.init(id: "terminal", kind: .terminal)], selected: "terminal"),
        ])))
        let generation = focus.beginIntent()
        var events: [String] = []
        await ChatColumnPlacement.followNewTabPages(["new-1", "new-2"], start: generation, generation: { focus.currentState().generation }, isDockCurrent: { true }, seed: {},
                                                     prepare: {
            focus.expect(.tab("terminal"), generation: generation)
            events.append("focus-respawn")
        }, isChosen: { _ in false }) { page, index in
            #expect(focus.state.pane == "strip")
            events.append("\(page):\(index)")
            return true
        }
        #expect(events == ["focus-respawn", "new-1:1", "new-2:2"])
    }

    @MainActor @Test func aStaleDockStopsRemainingPageMoves() async {
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        let generation = focus.beginIntent()
        var current = true
        var moved: [String] = []
        await ChatColumnPlacement.followNewTabPages(["new-1", "new-2"], start: generation, generation: { focus.currentState().generation }, isDockCurrent: { current }, seed: {}, prepare: {}, isChosen: { _ in false }) { page, _ in
            moved.append(page)
            current = false
            return true
        }
        #expect(moved == ["new-1"])
    }

    @MainActor @Test func aMissingDockDoesNotPrepareOrMove() async {
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        let generation = focus.beginIntent()
        var events: [String] = []
        await ChatColumnPlacement.followNewTabPages(["new-1"], start: generation, generation: { focus.currentState().generation }, isDockCurrent: { false }, seed: { events.append("seed") },
                                                     prepare: { events.append("focus") }, isChosen: { _ in false }) { page, _ in
            events.append(page)
            return true
        }
        #expect(events.isEmpty)
    }

    @MainActor @Test func aFailedPageMoveContinuesWithoutAdvancingTheInsertionIndex() async {
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        let generation = focus.beginIntent()
        var moves: [String] = []
        await ChatColumnPlacement.followNewTabPages(["new-1", "new-2", "new-3"], start: generation, generation: { focus.currentState().generation }, isDockCurrent: { true }, seed: {}, prepare: {}, isChosen: { _ in false }) { page, index in
            moves.append("\(page):\(index)")
            return page != "new-1"
        }
        #expect(moves == ["new-1:1", "new-2:1", "new-3:2"])
    }

    /// A newer click or key keeps the focus the person chose, but the new dock still selects its
    /// chat. A page the person selected meanwhile stays where they are working; another page moves.
    @MainActor @Test(arguments: [false, true])
    func newerSelectionOrFocusKeepsFocusAndAChosenPage(selectTab: Bool) async {
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        focus.send(.topology(FocusTopology(workspace: "workspace", panes: [
            FocusTopology.Pane(id: "source", tabs: [.init(id: "chat", kind: .agent), .init(id: "page", kind: .agent)], selected: "chat"),
            FocusTopology.Pane(id: "other", tabs: [.init(id: "terminal", kind: .terminal)], selected: "terminal"),
        ])))
        let generation = focus.beginIntent()
        if selectTab {
            focus.send(.selectTab(pane: "source", tab: "page", source: .mouse))
        } else {
            focus.send(.focusPane("other", source: .keyboard))
        }
        var seeded = false, prepared = false
        var moved: [String] = []
        await ChatColumnPlacement.followNewTabPages(["page"], start: generation, generation: { focus.currentState().generation },
                                                     isDockCurrent: { true }, seed: { seeded = true }, prepare: { prepared = true },
                                                     isChosen: { focus.currentState().topology.pane("source")?.selected == $0 }) { page, _ in
            moved.append(page)
            return true
        }
        #expect(seeded)
        #expect(!prepared)
        #expect(moved == (selectTab ? [] : ["page"]))
    }

    /// Without a newer intent nothing counts as chosen: every page follows the chat, in order.
    @MainActor @Test func pagesFollowInOrderWhenNothingNewerHappened() async {
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        let generation = focus.beginIntent()
        var moved: [String] = []
        await ChatColumnPlacement.followNewTabPages(["page-1", "page-2"], start: generation, generation: { focus.currentState().generation },
                                                     isDockCurrent: { true }, seed: {}, prepare: {}, isChosen: { _ in true }) { page, _ in
            moved.append(page)
            return true
        }
        #expect(moved == ["page-1", "page-2"])
    }

    /// The run's own focus change in `prepare` is not the person's: the pages still follow.
    @MainActor @Test func theRunsOwnFocusChangeDoesNotKeepPagesBehind() async {
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        focus.send(.topology(FocusTopology(workspace: "workspace", panes: [
            FocusTopology.Pane(id: "dock", tabs: [.init(id: "chat", kind: .agent)], selected: "chat"),
            FocusTopology.Pane(id: "other", tabs: [.init(id: "terminal", kind: .terminal)], selected: "terminal"),
        ])))
        let generation = focus.beginIntent()
        var moved: [String] = []
        await ChatColumnPlacement.followNewTabPages(["page-1", "page-2"], start: generation, generation: { focus.currentState().generation },
                                                     isDockCurrent: { true }, seed: {}, prepare: {
            focus.send(.focusPane("dock", source: .keyboard))
        }, isChosen: { _ in true }) { page, _ in
            moved.append(page)
            return true
        }
        #expect(moved == ["page-1", "page-2"])
    }

    @Test func newTabPagesFollowTheChatInTheirOriginalOrder() {
        let tabs: [(id: String, kind: Tab)] = [("new-1", .newTab), ("chat", .chat), ("term", .terminal), ("new-2", .newTab)]
        #expect(ChatColumnPlacement.newTabPages(in: tabs) { $0.kind == .newTab }.map(\.id) == ["new-1", "new-2"])
    }

    @Test func theDockTakesTheChatNotANewTabPageBeforeIt() {
        let tabs: [(id: String, kind: Tab)] = [("new", .newTab), ("chat", .chat)]
        let chat = ChatColumnPlacement.loneChat(in: tabs, isChat: { $0.kind == .chat }, isNewTabPage: { $0.kind == .newTab })
        #expect(chat?.id == "chat")
    }

    @MainActor @Test func aSelectionDuringPageMovesIsNotRestoredAtTheEnd() async {
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        focus.send(.topology(FocusTopology(workspace: "workspace", panes: [
            .init(id: "dock", tabs: [.init(id: "chat", kind: .agent), .init(id: "page", kind: .agent)], selected: "chat"),
            .init(id: "strip", tabs: [.init(id: "terminal", kind: .terminal)], selected: "terminal"),
        ])))
        let generation = focus.beginIntent()
        var preparations = 0
        await ChatColumnPlacement.followNewTabPages(["page-1", "page-2"], start: generation, generation: { focus.currentState().generation },
                                                     isDockCurrent: { true }, seed: {}, prepare: {
            preparations += 1
            focus.expect(.tab("terminal"), generation: generation)
        }, isChosen: { _ in false }) { _, _ in
            focus.send(.selectTab(pane: "dock", tab: "page", source: .mouse))
            return true
        }
        #expect(preparations == 1)
        #expect(focus.state.pane == "dock")
        #expect(focus.state.topology.pane("dock")?.selected == "page")
    }


    @MainActor @Test func aDockCanBeListedBeforeMountingAndStopsBeingCurrentWhenRemoved() async throws {
        let store = DaemonStore()
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: [
            ColumnSnapshot(id: 1, width: 0.5, layout: .leaf(1), dock: .init(edge: .left, mode: .docked, role: .agentChat)),
        ], panes: [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Chat")])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace", screens: [screen])]))
        let dock = try #require(store.workspaces.first?.screens.first?.panes.first)
        #expect(ChatDockRules.isChatDock(dock, in: store))
        let focus = FocusCoordinator()
        focus.closeFocus = { .previousNeighbor }
        let generation = focus.beginIntent()
        var moved: [String] = []
        await ChatColumnPlacement.followNewTabPages(["page-1", "page-2"], start: generation, generation: { focus.currentState().generation },
                                                     isDockCurrent: { ChatDockRules.isChatDock(dock, in: store) }, seed: {}, prepare: {},
                                                     isChosen: { _ in false }) { page, _ in
            moved.append(page)
            store.apply(snapshot: DaemonTree(workspaces: []))
            return true
        }
        #expect(moved == ["page-1"])
        #expect(!ChatDockRules.isChatDock(dock, in: store))
    }

}
