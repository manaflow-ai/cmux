@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextFocus
import Testing

/// #36896 (gap 2): a focus event is judged by the run that sent it. An event sent while the coordinator drains (by an
/// effect or the settled observer, for example the held keys the New Tab hold gives back, which go on with no run scope)
/// is queued and reduced by the drain's loop. That loop read the menu-pick mark of the drain's own run, so the queued
/// event counted as the person's menu choice although no menu chose it.
@MainActor struct FocusQueuedMenuPickTests {
    private static let topology = FocusTopology(workspace: "w", panes: [
        .init(id: "a", tabs: [.init(id: "a-tab", kind: .terminal)], selected: "a-tab"),
        .init(id: "b", tabs: [.init(id: "b-tab", kind: .terminal)], selected: "b-tab"),
    ])

    /// A menu pick's own move counts once; a programmatic move sent with no run scope from its settle does not count.
    @Test func anEventQueuedDuringAMenuPicksDrainKeepsItsOwnRunsJudgment() {
        let focus = FocusCoordinator(machine: FocusMachine())
        focus.send(.topology(Self.topology))
        focus.send(.focusPane("a", source: .programmatic))
        let before = focus.state.personMoveSeq
        var replayed = false
        focus.settledObserver = { _ in
            guard !replayed else { return }
            replayed = true
            // What a replayed key's own action sends after the hold gives the key back (`NewTabInputBuffer.release`).
            ActionRunScope.carrying(nil) { focus.send(.focusPane("a", source: .programmatic)) }
        }
        ActionRunScope.$current.withValue(ActionRunScope(origin: .user, allowsViewChange: true, menuPick: true)) {
            focus.send(.focusPane("b", source: .programmatic))
        }
        #expect(replayed, "the settle never sent the replayed move")
        #expect(focus.state.pane == "a", "the replayed move was not reduced")
        #expect(focus.state.personMoveSeq == before &+ 1,
                "the menu pick's move counts once and the replayed programmatic move not at all: \(before) -> \(focus.state.personMoveSeq)")
    }

    /// The other side: an event queued inside a menu pick's own run (its effects' follow-up) still counts as its choice.
    @Test func anEventQueuedInsideTheMenuPicksRunStillCounts() {
        let focus = FocusCoordinator(machine: FocusMachine())
        focus.send(.topology(Self.topology))
        focus.send(.focusPane("a", source: .programmatic))
        let before = focus.state.personMoveSeq
        var queued = false
        focus.settledObserver = { _ in
            guard !queued else { return }
            queued = true
            focus.send(.focusPane("a", source: .programmatic))
        }
        ActionRunScope.$current.withValue(ActionRunScope(origin: .user, allowsViewChange: true, menuPick: true)) {
            focus.send(.focusPane("b", source: .programmatic))
        }
        #expect(queued)
        #expect(focus.state.pane == "a")
        #expect(focus.state.personMoveSeq == before &+ 2, "both moves of the menu pick's run count: \(before) -> \(focus.state.personMoveSeq)")
    }
}
