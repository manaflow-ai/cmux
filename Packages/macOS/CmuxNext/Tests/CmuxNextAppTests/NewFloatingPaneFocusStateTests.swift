import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextFocus
import Testing

/// New Floating Pane and the focus state of the window: after the act, the pane that the window's focus state names
/// is the new pane, so Float Pane with no named pane and the person's keys go to it (decision 2026-11-16). The act
/// runs with the 2 stand-in requests of `NewFloatingPaneTests.Fixture` and with the app's focus coordinator and its
/// reducer. The window's side is the 2 coordinator calls that the window's 2 functions make (`beginIntent` and
/// `expect`), and the key of the request is made as the window makes it: the tab's id when the store has the tab.
///
/// A run that may not change this client's view (a script or the control socket with no `focus: true`) makes the pane
/// and floats it, and the focus state stays as it is: the rule of `FocusCoordinator.send`, held here.
///
/// Not in these tests: the app's line that gives the act the 2 functions of its window, the window's own topology
/// send, and the origin that a person's key, menu item or palette pick gives its run.
@MainActor struct NewFloatingPaneFocusStateTests {
    /// One window: the act's fixture with one tiled pane, and a focus coordinator whose state names that pane.
    @MainActor final class Window {
        let fixture: NewFloatingPaneTests.Fixture
        let focus: FocusCoordinator
        /// Whether the topology with the new pane comes to the coordinator before the act's focus request. The window
        /// sends its topology when the store changes: that is before the request or after it.
        let topologyFirst: Bool
        /// The key of each focus request of the act, made as the window makes it.
        var keys: [FocusState.Expectation.Key] = []

        init(topologyFirst: Bool) {
            fixture = NewFloatingPaneTests.Fixture(columns: [NewFloatingPaneTests.Column(panes: [1])])
            focus = FocusCoordinator(machine: FocusMachine())
            self.topologyFirst = topologyFirst
            sendTopology()
            focus.send(.focusPane(id(1) ?? "", source: .programmatic))
        }

        /// The id that the focus state has for the pane with the handle `handle`.
        func id(_ handle: PaneID) -> String? { fixture.store.pane(handle)?.id }

        /// Gives the coordinator the store's screen in the form of the window's topology: each pane by its id, each tab
        /// by its id. A topology that is equal to the last one changes nothing.
        func sendTopology() {
            let panes = fixture.store.screen(1)?.panes ?? []
            focus.send(.topology(FocusTopology(workspace: "w", panes: panes.map { pane in
                FocusTopology.Pane(id: pane.id, tabs: pane.tabs.map { FocusTopology.Tab(id: $0.id, kind: .terminal) }, selected: pane.tabs.first?.id)
            })))
        }

        /// Runs the act as the action registry runs a handler: `scope` is in force in the handler's turn, where the
        /// intent starts, and in the task that the handler starts, where the 2 requests and the focus request go.
        func run(_ scope: ActionRunScope) async -> ActionWorkFailure? {
            let fixture = self.fixture, focus = self.focus
            let window = NewPaneFocus(begin: { focus.beginIntent() }) { surface, generation in
                if self.topologyFirst { self.sendTopology() }
                // As `WorkspaceContentController.expectFocus`: a tab that the store has goes by its id.
                let key: FocusState.Expectation.Key = fixture.store.tab(surface: surface).map { .tab($0.id) } ?? .surface(String(surface.rawValue))
                self.keys.append(key)
                focus.expect(key, generation: generation)
            }
            let work = ActionRunScope.carrying(scope) { () -> ActionWork in
                let request = window.started()
                return Task { @MainActor in await fixture.run(beside: 1, focus: request) }
            }
            let failure = await work.value
            // The float changed the store: the window sends its topology again.
            sendTopology()
            return failure
        }
    }

    /// What one run of the act in a new window gave.
    struct Run {
        /// The pane that had the focus before the act, and the pane that the act made.
        let old: String, new: String
        /// The intent generation before the act.
        let generation: UInt64
        /// The focus state after the act.
        let state: FocusState
        /// The key of each focus request of the act, and the key that names the new pane's tab by its id.
        let keys: [FocusState.Expectation.Key], tab: FocusState.Expectation.Key
    }

    /// Runs the act with `scope` from the one tiled pane of a new window. In each case the act has no failure and the
    /// new pane floats.
    private static func run(_ scope: ActionRunScope, topologyFirst: Bool) async throws -> Run {
        let window = Window(topologyFirst: topologyFirst)
        let old = try #require(window.id(1))
        try #require(window.focus.state.pane == old, "the tiled pane has the focus before the act")
        let generation = window.focus.state.generation
        let failure = await window.run(scope)
        #expect(failure == nil)
        #expect(window.fixture.floatingInStore == [10], "the new pane floats")
        let tab = try #require(window.fixture.store.tab(surface: 110)?.id)
        let new = try #require(window.id(10))
        return Run(old: old, new: new, generation: generation, state: window.focus.state, keys: window.keys, tab: .tab(tab))
    }

    /// A person's run (a key, a menu item, a palette pick): the focus state names the new pane.
    @Test(arguments: [true, false])
    func aPersonsNewFloatingPaneIsTheFocusedPaneOfTheWindowsState(topologyFirst: Bool) async throws {
        let run = try await Self.run(ActionRunScope(origin: .user, allowsViewChange: true), topologyFirst: topologyFirst)
        // The store has the new pane's tab when the act asks, so the request names the tab by its id, not by its surface.
        #expect(run.keys == [run.tab], "one focus request, by the id of the new pane's tab")
        #expect(run.state.pane == run.new, "Float Pane with no named pane reads this pane: it must be the new one")
        #expect(run.state.generation == run.generation &+ 1, "the act is one intent of the person")
    }

    /// A run that may not change the view: the pane is made and floats, the focus state does not move.
    @Test(arguments: [true, false])
    func aRunThatMayNotChangeTheViewFloatsThePaneAndKeepsTheFocusedPane(topologyFirst: Bool) async throws {
        let run = try await Self.run(ActionRunScope(origin: .cli, allowsViewChange: false), topologyFirst: topologyFirst)
        #expect(run.state.pane == run.old, "a run with no focus request never moves the person's focus")
        #expect(run.state.generation == run.generation, "and it starts no intent")
    }

    /// A script's run with `focus: true` may change the view: the focus state names the new pane.
    @Test(arguments: [true, false])
    func aScriptsRunWithTheFocusFlagGivesTheNewPaneTheFocus(topologyFirst: Bool) async throws {
        let run = try await Self.run(ActionRunScope(origin: .cli, allowsViewChange: true), topologyFirst: topologyFirst)
        #expect(run.keys == [run.tab])
        #expect(run.state.pane == run.new)
        #expect(run.state.generation == run.generation &+ 1)
    }
}
