@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Focus after a close through the focus reducer (plans/cmux-next/close-focus.md).
/// B1 and B2 reproduce the bugs seen live on ef59984a2f1: the successor was
/// the most recently focused pane anywhere, so closing a split pane jumped
/// to another column and closing a column jumped right instead of left.
struct CloseFocusReducerTests {
    typealias Pane = FocusTopology.Pane

    static func pane(_ id: String) -> Pane {
        Pane(id: id, tabs: [FocusTopology.Tab(id: "t-\(id)", surface: "s-\(id)", kind: .terminal)], selected: "t-\(id)")
    }

    /// One screen, columns in visual order.
    static func topology(_ columns: [[String]], workspace: String = "w") -> FocusTopology {
        FocusTopology(workspace: workspace, panes: columns.flatMap { $0 }.map(pane), screens: [columns])
    }

    static func run(_ events: [FocusEvent], from start: FocusState = FocusState()) -> FocusState {
        events.reduce(start) { FocusReducer.reduce($0, $1).0 }
    }

    static func focused(_ order: [String], in columns: [[String]], policy: CloseFocusPolicy = .previousNeighbor) -> FocusState {
        var state = FocusState()
        state.closeFocus = policy
        return run([.windowKey(true), .topology(topology(columns))] + order.map { .focusPane($0, source: .mouse) }, from: state)
    }

    // B1: closing the lower pane of a split returns to the pane above it,
    // not to the most recently focused pane in another column.
    @Test func closingASplitPaneFocusesThePreviousPaneInItsColumn() {
        let columns = [["a"], ["b", "c"], ["d"]]
        var state = Self.focused(["b", "a", "c"], in: columns)
        state = Self.run([.topology(Self.topology([["a"], ["b"], ["d"]]))], from: state)
        #expect(state.pane == "b")
    }

    @Test func closingTheFirstPaneOfAColumnFocusesTheNextPaneThere() {
        var state = Self.focused(["d", "b"], in: [["a"], ["b", "c"], ["d"]])
        state = Self.run([.topology(Self.topology([["a"], ["c"], ["d"]]))], from: state)
        #expect(state.pane == "c")
    }

    // B2: closing the last pane of a middle column goes to the column on
    // its left, entering it at its most recently focused pane.
    @Test func closingAColumnFocusesTheColumnToTheLeft() {
        var state = Self.focused(["a2", "a1", "d", "c"], in: [["a1", "a2"], ["c"], ["d"]])
        state = Self.run([.topology(Self.topology([["a1", "a2"], ["d"]]))], from: state)
        #expect(state.pane == "a1")
    }

    @Test func closingTheFirstColumnFocusesTheColumnToTheRight() {
        var state = Self.focused(["c", "a"], in: [["a"], ["b1", "b2"], ["c"]])
        state = Self.run([.topology(Self.topology([["b1", "b2"], ["c"]]))], from: state)
        #expect(state.pane == "b1")
    }

    // Sticky columns are columns for focus: the right sticky column's left
    // neighbor is the strip's last column, the left one's is the first.
    @Test func closingTheStickyColumnFocusesTheNearestScrollingColumn() {
        var state = Self.focused(["s1", "R"], in: [["L"], ["s1"], ["s2"], ["R"]])
        state = Self.run([.topology(Self.topology([["L"], ["s1"], ["s2"]]))], from: state)
        #expect(state.pane == "s2")
        state = Self.focused(["s2", "L"], in: [["L"], ["s1"], ["s2"], ["R"]])
        state = Self.run([.topology(Self.topology([["s1"], ["s2"], ["R"]]))], from: state)
        #expect(state.pane == "s1")
    }

    @Test func mostRecentPolicyReturnsToThePreviouslyFocusedPane() {
        var state = Self.focused(["b", "a", "c"], in: [["a"], ["b", "c"], ["d"]], policy: .mostRecent)
        state = Self.run([.topology(Self.topology([["a"], ["b"], ["d"]]))], from: state)
        #expect(state.pane == "a")
    }

    // C1: closing an unfocused pane (by the user, the CLI, another client
    // or the daemon) never moves focus.
    @Test func closingAnUnfocusedPaneKeepsFocus() {
        var state = Self.focused(["a", "c"], in: [["a"], ["b", "c"], ["d"]])
        for columns in [[["a"], ["b", "c"]], [["b", "c"]], [["c"]]] {
            state = Self.run([.topology(Self.topology(columns))], from: state)
            #expect(state.pane == "c")
        }
    }

    // A pending close hides the pane at once; a reject brings it back.
    // Focus stays on the successor (no jump back on its own).
    @Test func aRejectedCloseDoesNotMoveFocusBack() {
        var state = Self.focused(["a", "b"], in: [["a"], ["b"], ["c"]])
        state = Self.run([.topology(Self.topology([["a"], ["c"]]))], from: state)
        #expect(state.pane == "a")
        state = Self.run([.topology(Self.topology([["a"], ["b"], ["c"]]))], from: state)
        #expect(state.pane == "a")
    }

    // C2: a pane on a hidden screen is never the successor while the
    // closed pane's screen has one.
    @Test func theSuccessorStaysOnTheSameScreen() {
        var state = FocusState()
        let before = FocusTopology(workspace: "w", panes: ["x", "a", "b"].map(Self.pane), screens: [[["x"]], [["a"], ["b"]]])
        state = Self.run([.windowKey(true), .topology(before), .focusPane("x", source: .mouse), .focusPane("b", source: .mouse)], from: state)
        let after = FocusTopology(workspace: "w", panes: ["x", "a"].map(Self.pane), screens: [[["x"]], [["a"]]])
        state = Self.run([.topology(after)], from: state)
        #expect(state.pane == "a")
    }
}
