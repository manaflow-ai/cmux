@testable import CmuxNextDesign
import Testing

/// The Swift owner of the close-selection state (`cmux_close_selection_*`): the ids it numbers for the rule, and
/// what it asks of the caller. The rule's own table is in cmux-focus-core's tests.
struct CloseSelectionTests {
    @Test func aNewItemReturnsToItsOpenerUntilItLeft() {
        let state = CloseSelection<String>(), strip = ["a", "b", "n", "c"]
        state.made("n", opener: "b", kind: .task, foreground: false) { strip.contains($0) }
        #expect(state.opener(of: "n") == "b")
        #expect(!state.isEmpty)
        #expect(state.workspace(shown: "n", old: strip, surviving: ["a", "b", "c"], orders: [strip]) == "b")
        state.left("n")
        #expect(state.isEmpty)
        #expect(state.opener(of: "n") == nil)
    }

    @Test func aQuickOpenerEndsWhenTheSelectionLeavesItsItem() {
        let state = CloseSelection<String>(), strip = ["a", "b", "n"]
        state.made("n", opener: "a", kind: .quick, foreground: true) { strip.contains($0) }
        state.selected(old: "n", new: "b", gesture: false) { strip.contains($0) }
        #expect(state.isEmpty)
        #expect(state.workspace(shown: "n", old: strip, surviving: ["a", "b"], orders: [strip]) == "b")
    }

    /// An id that was never in a `made` is numbered for one pick only: the state keeps nothing of it.
    @Test func aPickWithNoRelationIsByPosition() {
        let state = CloseSelection<String>()
        #expect(state.workspace(shown: "b", old: ["a", "b", "c"], surviving: ["a", "c"], orders: [["a", "b", "c"]]) == "c")
        #expect(state.workspace(shown: "c", old: ["a", "b", "c"], surviving: ["a", "b"], orders: [["a", "b", "c"]]) == "b")
        #expect(state.workspace(shown: "a", old: ["a", "b"], surviving: ["a"]) == "a")
        #expect(state.isEmpty)
    }

    /// With no relation held, a selection change asks the caller nothing (no strip is built).
    @Test func aSelectionChangeWithNoRelationAsksNothing() {
        let state = CloseSelection<String>()
        var asked = 0
        state.selected(old: "a", new: "b", gesture: true) { _ in asked += 1; return true }
        state.left("a")
        #expect(asked == 0)
    }
}
