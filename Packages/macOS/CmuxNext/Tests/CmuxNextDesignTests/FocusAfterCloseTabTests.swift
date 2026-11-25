@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Closing the selected tab with no opener relation selects the NEXT shown tab, and the previous one
/// only when it was the last. Changed from "the tab before" (#38316, #38328, #38419) by the one
/// close-selection rule: /work/wt/handoff/tasks/close-selection-rule.md (R1 rank 4 and its
/// DECISION 14:20Z; plans/cmux-next/close-focus.md, "One close-selection rule"). The rows with an
/// opener are in `TabCloseSelectionTests`.
struct FocusAfterCloseTabTests {
    private static func pick(_ closed: String, in old: [String], hidden: Set<String> = []) -> String? {
        let surviving = old.filter { $0 != closed }
        return CloseSelection<String>().successor(ofTab: closed, old: old, surviving: surviving, shown: Set(surviving).subtracting(hidden))
    }

    @Test func theNextTabElseThePreviousTab() {
        #expect(Self.pick("B", in: ["A", "B", "C"]) == "C")
        #expect(Self.pick("A", in: ["A", "B", "C"]) == "B")
        // The last tab: the tab before it.
        #expect(Self.pick("C", in: ["A", "B", "C"]) == "B")
        #expect(Self.pick("A", in: ["A"]) == nil)
    }

    @Test func aHiddenTabIsSkipped() {
        // A and B sit in a collapsed group: the nearest shown tab after T is C.
        #expect(Self.pick("T", in: ["T", "A", "B", "C"], hidden: ["A", "B"]) == "C")
        // None shown after: the shown tab before.
        #expect(Self.pick("C", in: ["T", "A", "B", "C"], hidden: ["A", "B"]) == "T")
        // None shown at all: the nearest surviving tab (its group then expands).
        #expect(Self.pick("C", in: ["A", "B", "C"], hidden: ["A", "B"]) == "B")
    }

    @Test func aSurvivingSelectionStays() {
        #expect(CloseSelection<String>().successor(ofTab: "A", old: ["A", "B"], surviving: ["A"], shown: ["A"]) == "A")
    }

    @Test func liveOpenersSkipTabsThatLeft() {
        // B left: C, which B opened, takes B's opener A (Chrome's FixOpeners), for where a link's tab goes.
        #expect(FocusAfterClose.liveOpeners(["B": "A", "C": "B"], among: ["A", "C"]) == ["C": "A"])
        #expect(FocusAfterClose.liveOpeners(["B": "A", "C": "Z"], among: ["B", "C"]).isEmpty)
        #expect(FocusAfterClose.liveOpeners(["A": "X", "X": "Y", "Y": "X"], among: ["A"]).isEmpty)
        #expect(FocusAfterClose.liveOpeners(["A": "X", "X": "A"], among: ["A"]).isEmpty)
    }

    /// Every strip of up to 5 tabs, every hidden set, every closed tab: the pick is the nearest shown
    /// tab after the closed one, else the nearest shown one before it, else the nearest surviving one
    /// after, else before; none only when no tab is left (close-selection-rule.md, R1 rank 4).
    @Test func everySmallStripPicksTheNextTab() {
        var checked = 0
        for count in 1...5 {
            let tabs = (0..<count).map { "t\($0)" }
            for mask in 0..<(1 << count) {
                let hidden = Set(tabs.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
                for (index, closed) in tabs.enumerated() {
                    checked += 1
                    let before = tabs[..<index].reversed(), after = tabs[(index + 1)...]
                    let expected = after.first { !hidden.contains($0) } ?? before.first { !hidden.contains($0) }
                        ?? after.first ?? before.first
                    #expect(Self.pick(closed, in: tabs, hidden: hidden) == expected, "closing \(closed) of \(tabs), hidden \(hidden)")
                }
            }
        }
        #expect(checked > 200)
    }
}
