@testable import CmuxNextApp
import CmuxNextLayout
import CoreGraphics
import Testing

/// Directional focus with history (plans/cmux-next/focus.md section 4a):
/// the reducer keeps each workspace's focus history from every source, and
/// directional navigation picks the most recently focused of the adjacent
/// panes (tmux `window_pane_choose_best`, zellij `max_by_key(active_at)`),
/// falling back to geometry only when none of them has history.
struct FocusHistoryNavigationTests {
    typealias Pane = FocusTopology.Pane

    static func topology(_ ids: [String], workspace: String = "w") -> FocusTopology {
        FocusTopology(workspace: workspace, panes: ids.map {
            Pane(id: $0, tabs: [FocusTopology.Tab(id: "t-\($0)", surface: "s-\($0)", kind: .terminal)], selected: "t-\($0)")
        })
    }

    static func reduce(_ events: [FocusEvent], from start: FocusState = FocusState()) -> FocusState {
        events.reduce(start) { FocusReducer.reduce($0, $1).0 }
    }

    static func loaded(_ ids: [String], workspace: String = "w") -> FocusState {
        reduce([.windowKey(true), .topology(topology(ids, workspace: workspace))])
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// One directional move, as `PaneHandlers` does it: navigate from the
    /// focused pane with the state's history, then focus the result.
    static func move(_ direction: LayoutDirection, _ state: FocusState, frames: [String: CGRect],
                     columns: [[String]] = [], source: FocusEvent.Source = .keyboard) -> (FocusState, String?) {
        guard let pane = state.pane else { return (state, nil) }
        var layoutFrames: [PaneID: CGRect] = [:]
        for (id, frame) in frames { layoutFrames[PaneID(id)] = frame }
        let next = FocusNavigation.neighbor(
            of: PaneID(pane), direction: direction, frames: layoutFrames,
            recency: state.recentPanes.map(PaneID.init(rawValue:)),
            columns: columns.map { $0.map(PaneID.init(rawValue:)) }
        )?.rawValue
        guard let next else { return (state, nil) }
        return (reduce([.focusPane(next, source: source)], from: state), next)
    }

    /// A | (B over C); B is taller, so geometry alone picks B from A.
    static let aBesideStack: [String: CGRect] = [
        "a": rect(0, 0, 100, 200), "b": rect(101, 0, 100, 120), "c": rect(101, 121, 100, 79),
    ]

    // MARK: History wins over geometry

    @Test func leftThenRightReturnsToThePaneYouCameFrom() {
        var state = Self.reduce([.focusPane("c", source: .mouse)], from: Self.loaded(["a", "b", "c"]))
        var moved: String?
        (state, moved) = Self.move(.left, state, frames: Self.aBesideStack)
        #expect(moved == "a")
        (state, moved) = Self.move(.right, state, frames: Self.aBesideStack)
        #expect(moved == "c")
        #expect(state.pane == "c")
    }

    @Test func withoutHistoryGeometryDecides() {
        let state = Self.loaded(["a", "b", "c"])
        #expect(state.recentPanes == ["a"])
        #expect(Self.move(.right, state, frames: Self.aBesideStack).1 == "b")
    }

    @Test(arguments: [FocusEvent.Source.mouse, .keyboard, .cli, .palette, .programmatic])
    func everyFocusSourceUpdatesHistory(source: FocusEvent.Source) {
        let state = Self.reduce([.focusPane("c", source: source), .focusPane("a", source: .keyboard)],
                                from: Self.loaded(["a", "b", "c"]))
        #expect(state.recentPanes.prefix(2) == ["a", "c"])
        #expect(Self.move(.right, state, frames: Self.aBesideStack).1 == "c")
    }

    @Test func responderAndLandedExpectationUpdateHistory() {
        // A click reported by AppKit (responder) and a split that lands
        // (expectation) are focus changes too.
        var state = Self.reduce([.responder(.content(pane: "c"), source: .mouse)], from: Self.loaded(["a", "b", "c"]))
        #expect(state.recentPanes.first == "c")
        state = Self.reduce([.focusPane("a", source: .keyboard), .expect(.surface("s-b"), target: .content, generation: state.generation + 1)],
                            from: state)
        #expect(state.recentPanes.first == "b")
    }

    // MARK: Layouts

    @Test func stackOnTheLeftRemembersItsLowerPane() {
        // (A over B) | C: from B right to C, then left goes back to B, not A.
        let frames = ["a": Self.rect(0, 0, 100, 99), "b": Self.rect(0, 100, 100, 100), "c": Self.rect(101, 0, 100, 200)]
        var state = Self.reduce([.focusPane("b", source: .mouse)], from: Self.loaded(["a", "b", "c"]))
        var moved: String?
        (state, moved) = Self.move(.right, state, frames: frames)
        #expect(moved == "c")
        (state, moved) = Self.move(.left, state, frames: frames)
        #expect(moved == "b")
    }

    @Test func wideTopPaneReturnsToTheLowerRightPane() {
        // T over (C | D): up from D to T, down returns to D, not C.
        let frames = ["t": Self.rect(0, 0, 201, 100), "c": Self.rect(0, 101, 100, 100), "d": Self.rect(101, 101, 100, 100)]
        var state = Self.reduce([.focusPane("d", source: .mouse)], from: Self.loaded(["t", "c", "d"]))
        var moved: String?
        (state, moved) = Self.move(.up, state, frames: frames)
        #expect(moved == "t")
        (state, moved) = Self.move(.down, state, frames: frames)
        #expect(moved == "d")
        // Without history, down from T picks the top-left one (tmux: first in layout order).
        #expect(Self.move(.down, Self.reduce([.focusPane("t", source: .mouse)], from: Self.loaded(["t", "c", "d"])), frames: frames).1 == "c")
    }

    @Test func gridMovesStayAdjacent() {
        let frames = ["a": Self.rect(0, 0, 100, 100), "b": Self.rect(101, 0, 100, 100),
                      "c": Self.rect(0, 101, 100, 100), "d": Self.rect(101, 101, 100, 100)]
        // History favors A, but from D only B is above and only C is left.
        var state = Self.reduce([.focusPane("a", source: .mouse), .focusPane("d", source: .mouse)], from: Self.loaded(["a", "b", "c", "d"]))
        #expect(Self.move(.up, state, frames: frames).1 == "b")
        #expect(Self.move(.left, state, frames: frames).1 == "c")
        state = Self.move(.up, state, frames: frames).0
        #expect(Self.move(.left, state, frames: frames).1 == "a")
    }

    @Test func historyNeverSkipsTheAdjacentColumn() {
        // A | B | C with A focused more recently than B: left from C is B.
        let frames = ["a": Self.rect(0, 0, 100, 200), "b": Self.rect(101, 0, 100, 200), "c": Self.rect(202, 0, 100, 200)]
        let state = Self.reduce([.focusPane("b", source: .mouse), .focusPane("a", source: .mouse), .focusPane("c", source: .mouse)],
                                from: Self.loaded(["a", "b", "c"]))
        #expect(Self.move(.left, state, frames: frames).1 == "b")
    }

    @Test func nestedSplitReturnsToTheInnerPane() {
        // A | (B over (C | D)): from D left to C, left to A, right returns to C.
        let frames = ["a": Self.rect(0, 0, 100, 200), "b": Self.rect(101, 0, 201, 99),
                      "c": Self.rect(101, 100, 100, 100), "d": Self.rect(202, 100, 100, 100)]
        var state = Self.reduce([.focusPane("d", source: .mouse)], from: Self.loaded(["a", "b", "c", "d"]))
        var moved: String?
        (state, moved) = Self.move(.left, state, frames: frames)
        #expect(moved == "c")
        (state, moved) = Self.move(.left, state, frames: frames)
        #expect(moved == "a")
        (state, moved) = Self.move(.right, state, frames: frames)
        #expect(moved == "c")
        // Up from C is B; down from B returns to C, not D.
        (state, moved) = Self.move(.up, state, frames: frames)
        #expect(moved == "b")
        (state, moved) = Self.move(.down, state, frames: frames)
        #expect(moved == "c")
    }

    @Test func splitThenCloseReturnsAndDropsTheClosedPane() {
        // Split A (B appears and lands), close B: focus returns to A and B
        // leaves the history.
        var state = Self.loaded(["a"])
        let intent = state.generation + 1
        state = Self.reduce([.beginIntent, .expect(.surface("s-b"), target: .content, generation: intent),
                             .topology(Self.topology(["a", "b"]))], from: state)
        #expect(state.pane == "b")
        #expect(state.recentPanes == ["b", "a"])
        state = Self.reduce([.topology(Self.topology(["a"]))], from: state)
        #expect(state.pane == "a")
        #expect(state.recentPanes == ["a"])
    }

    @Test func closedPaneNeverWinsDirectionalFocus() {
        var state = Self.reduce([.focusPane("c", source: .mouse), .focusPane("a", source: .mouse)], from: Self.loaded(["a", "b", "c"]))
        state = Self.reduce([.topology(Self.topology(["a", "b"]))], from: state)
        #expect(!state.recentPanes.contains("c"))
        // A new pane in C's place has no history: geometry picks B.
        state = Self.reduce([.topology(Self.topology(["a", "b", "e"]))], from: state)
        let frames = ["a": Self.rect(0, 0, 100, 200), "b": Self.rect(101, 0, 100, 120), "e": Self.rect(101, 121, 100, 79)]
        #expect(Self.move(.right, state, frames: frames).1 == "b")
    }

    // MARK: Workspaces, niri columns, screens

    @Test func historyIsPerWorkspace() {
        var state = Self.reduce([.focusPane("c", source: .mouse)], from: Self.loaded(["a", "b", "c"], workspace: "w1"))
        state = Self.reduce([.topology(Self.topology(["x", "y"], workspace: "w2")), .focusPane("y", source: .mouse)], from: state)
        #expect(state.recentPanes == ["y", "x"])
        #expect(state.history["w1"] == ["c", "a"])
        state = Self.reduce([.topology(Self.topology(["a", "b", "c"], workspace: "w1"))], from: state)
        #expect(state.pane == "c")
        #expect(state.recentPanes == ["c", "a"])
        #expect(Self.move(.left, state, frames: Self.aBesideStack).1 == "a")
    }

    @Test func cliFocusInABackgroundWorkspaceEntersItsHistory() {
        var state = Self.loaded(["a", "b"], workspace: "w1")
        state = Self.reduce([.focusPane("y", workspace: "w2", source: .cli)], from: state)
        #expect(state.history["w2"] == ["y"])
        #expect(state.recentPanes == ["a"])
    }

    @Test func niriColumnReturnsToItsActiveTile() {
        // Columns [A over B] [D over E]: B then D focused. Left from D is B
        // (the column's last focused tile), though A overlaps D.
        let frames = ["a": Self.rect(0, 0, 100, 99), "b": Self.rect(0, 100, 100, 100),
                      "d": Self.rect(101, 0, 100, 99), "e": Self.rect(101, 100, 100, 100)]
        let columns = [["a", "b"], ["d", "e"]]
        var state = Self.reduce([.focusPane("b", source: .mouse), .focusPane("d", source: .mouse)], from: Self.loaded(["a", "b", "d", "e"]))
        var moved: String?
        (state, moved) = Self.move(.left, state, frames: frames, columns: columns)
        #expect(moved == "b")
        (state, moved) = Self.move(.right, state, frames: frames, columns: columns)
        #expect(moved == "d")
        // A column never focused before: geometry (the overlapping tile).
        let fresh = Self.loaded(["a", "b", "d", "e"])
        #expect(Self.move(.right, fresh, frames: frames, columns: columns).1 == "d")
        // Up and down stay inside the column.
        #expect(Self.move(.down, state, frames: frames, columns: columns).1 == "e")
    }

    @Test func screenSwitchReturnsToTheScreensLastPane() {
        // Screen 1 holds a1, a2; screen 2 holds b1, b2 (one topology, screen order).
        let state = Self.reduce([.focusPane("a2", source: .mouse), .focusPane("b2", source: .keyboard), .focusPane("b1", source: .keyboard)],
                                from: Self.loaded(["a1", "a2", "b1", "b2"]))
        let recency = state.recentPanes.map(PaneID.init(rawValue:))
        #expect(FocusNavigation.mostRecent(["a1", "a2"], recency: recency) == "a2")
        #expect(FocusNavigation.mostRecent(["b1", "b2"], recency: recency) == "b1")
        #expect(FocusNavigation.mostRecent(["c1"], recency: recency) == nil)
    }

    @Test func historyIsBoundedPerWorkspace() {
        let ids = (0..<(FocusState.historyLimit + 10)).map { "p\($0)" }
        let state = Self.reduce(ids.map { .focusPane($0, source: .keyboard) }, from: Self.loaded(ids))
        #expect(state.recentPanes.count == FocusState.historyLimit)
        #expect(state.recentPanes.first == ids.last)
    }
}
