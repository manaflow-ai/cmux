@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Closing the selected tab selects the shown tab immediately before it, else the one after it
/// (Lawrence 2026-11-08: "it should always focus the tab before it if it exists"; close-focus.md,
/// Tab). No opener, history or "next to the right" order picks.
struct FocusAfterCloseTabTests {
    private static func pick(_ closed: String, in old: [String], hidden: Set<String> = []) -> String? {
        let surviving = old.filter { $0 != closed }
        return FocusAfterClose.tab(selected: closed, old: old, surviving: surviving, shown: Set(surviving).subtracting(hidden))
    }

    @Test func theTabBeforeElseTheTabAfter() {
        #expect(Self.pick("B", in: ["A", "B", "C"]) == "A")
        #expect(Self.pick("C", in: ["A", "B", "C"]) == "B")
        // The first tab: the tab after it.
        #expect(Self.pick("A", in: ["A", "B", "C"]) == "B")
        #expect(Self.pick("A", in: ["A"]) == nil)
    }

    @Test func aHiddenTabBeforeIsSkipped() {
        // A and B sit in a collapsed group: the nearest shown tab before C is T.
        #expect(Self.pick("C", in: ["T", "A", "B", "C", "D"], hidden: ["A", "B"]) == "T")
        // None shown before: the shown tab after.
        #expect(Self.pick("C", in: ["A", "B", "C", "D"], hidden: ["A", "B"]) == "D")
        // None shown at all: the nearest surviving tab before (its group then expands).
        #expect(Self.pick("C", in: ["A", "B", "C"], hidden: ["A", "B"]) == "B")
    }

    @Test func aSurvivingSelectionStays() {
        #expect(FocusAfterClose.tab(selected: "A", old: ["A", "B"], surviving: ["A"], shown: ["A"]) == "A")
    }

    @Test func liveOpenersSkipTabsThatLeft() {
        // B left: C, which B opened, takes B's opener A (Chrome's FixOpeners), for where a link's tab goes.
        #expect(FocusAfterClose.liveOpeners(["B": "A", "C": "B"], among: ["A", "C"]) == ["C": "A"])
        #expect(FocusAfterClose.liveOpeners(["B": "A", "C": "Z"], among: ["B", "C"]).isEmpty)
        #expect(FocusAfterClose.liveOpeners(["A": "X", "X": "Y", "Y": "X"], among: ["A"]).isEmpty)
        #expect(FocusAfterClose.liveOpeners(["A": "X", "X": "A"], among: ["A"]).isEmpty)
    }

    /// Every strip of up to 5 tabs, every hidden set, every closed tab: the pick is the nearest shown
    /// tab before the closed one, else the nearest shown one after it, else the nearest surviving one
    /// before, else after; none only when no tab is left.
    @Test func everySmallStripPicksTheTabBefore() {
        var checked = 0
        for count in 1...5 {
            let tabs = (0..<count).map { "t\($0)" }
            for mask in 0..<(1 << count) {
                let hidden = Set(tabs.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
                for (index, closed) in tabs.enumerated() {
                    checked += 1
                    let before = tabs[..<index].reversed(), after = tabs[(index + 1)...]
                    let expected = before.first { !hidden.contains($0) } ?? after.first { !hidden.contains($0) }
                        ?? before.first ?? after.first
                    #expect(Self.pick(closed, in: tabs, hidden: hidden) == expected, "closing \(closed) of \(tabs), hidden \(hidden)")
                }
            }
        }
        #expect(checked > 200)
    }
}
