@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Closing the selected link tab goes back to its opener family first, in
/// Chrome's order (`DetermineNewSelectedIndex`): its next child, else a
/// sibling, else its opener; then the next shown tab, else the previous
/// one (close-focus.md, Tab; manaflow-ai/cmux#21805 row 1).
struct FocusAfterCloseOpenerTests {
    private static func pick(_ closed: String, in old: [String], opener: [String: String] = [:],
                             hidden: Set<String> = []) -> String? {
        let surviving = old.filter { $0 != closed }
        return FocusAfterClose.tab(selected: closed, old: old, surviving: surviving,
                                   shown: Set(surviving).subtracting(hidden), opener: opener)
    }

    @Test func aClosedChildGoesBackToItsOpener() {
        // A link opened in a new tab, read, Cmd-W: back to the page it came from, not the tab on its right.
        #expect(Self.pick("B", in: ["A", "B", "C"], opener: ["B": "A"]) == "A")
    }

    @Test func aClosedChildPicksTheNextSiblingBeforeTheOpener() {
        let opener = ["B": "A", "C": "A", "D": "A"]
        #expect(Self.pick("B", in: ["A", "B", "C", "D", "X"], opener: opener) == "C")
        // The last child: the nearest sibling before it, not the unrelated tab on its right.
        #expect(Self.pick("D", in: ["A", "B", "C", "D", "X"], opener: opener) == "C")
    }

    @Test func aClosedOpenerPicksItsNextChild() {
        #expect(Self.pick("A", in: ["A", "X", "B"], opener: ["B": "A"]) == "B")
        // A child before it counts when none follows (Chrome searches after, then before).
        #expect(Self.pick("A", in: ["B", "X", "A", "Y"], opener: ["B": "A"]) == "B")
    }

    @Test func aChildComesBeforeASibling() {
        // B opened C and was itself opened by A, like A's other child D.
        let opener = ["B": "A", "C": "B", "D": "A"]
        #expect(Self.pick("B", in: ["A", "B", "D", "C"], opener: opener) == "C")
    }

    @Test func forgottenOpenersFallBackToTheRightNeighbor() {
        // After a switch to an unrelated tab every relation is forgotten (`BrowserTabOpeners.userActivated`).
        #expect(Self.pick("B", in: ["A", "B", "C"]) == "C")
        #expect(Self.pick("C", in: ["A", "B", "C"]) == "B")
    }

    @Test func tabsWithoutRelationsKeepNextElsePrevious() {
        // A terminal next to a link family: it has no relation, so the family is not consulted.
        #expect(Self.pick("T", in: ["A", "T", "B"], opener: ["B": "A"]) == "B")
        #expect(Self.pick("T", in: ["B", "A", "T"], opener: ["B": "A"]) == "A")
    }

    @Test func aHiddenOpenerIsSkipped() {
        // The opener sits in a collapsed group: the right neighbor, not a hidden tab.
        #expect(Self.pick("B", in: ["A", "B", "C"], opener: ["B": "A"], hidden: ["A"]) == "C")
        // A hidden sibling is skipped too; the shown opener comes next.
        #expect(Self.pick("B", in: ["A", "B", "C", "X"], opener: ["B": "A", "C": "A"], hidden: ["C"]) == "A")
        // A hidden child is skipped; with no other relation, the right neighbor.
        #expect(Self.pick("A", in: ["A", "X", "B"], opener: ["B": "A"], hidden: ["B"]) == "X")
    }

    @Test func liveOpenersSkipTabsThatLeft() {
        // B left: C, which B opened, takes B's opener A (Chrome's FixOpeners).
        #expect(FocusAfterClose.liveOpeners(["B": "A", "C": "B"], among: ["A", "C"]) == ["C": "A"])
        // Only tabs in the order are keys; a chain that leads nowhere present is dropped.
        #expect(FocusAfterClose.liveOpeners(["B": "A", "C": "Z"], among: ["B", "C"]).isEmpty)
        // A cycle through tabs that left ends, and a relation back to the tab itself is dropped.
        #expect(FocusAfterClose.liveOpeners(["A": "X", "X": "Y", "Y": "X"], among: ["A"]).isEmpty)
        #expect(FocusAfterClose.liveOpeners(["A": "X", "X": "A"], among: ["A"]).isEmpty)
    }

    @Test func aSurvivingSelectionStays() {
        #expect(FocusAfterClose.tab(selected: "A", old: ["A", "B"], surviving: ["A"], shown: ["A"], opener: ["B": "A"]) == "A")
    }

    /// Every strip of up to 4 tabs, every opener forest, every hidden set,
    /// every closed tab: the pick is a surviving shown tab while one is
    /// left (C2, C3), and it differs from the plain rule only for a tab of
    /// the closed tab's family (child, sibling or opener).
    @Test func everySmallStripKeepsTheContract() {
        var checked = 0
        for count in 1...4 {
            let tabs = (0..<count).map { "t\($0)" }
            for opener in Self.forests(tabs) {
                for mask in 0..<(1 << count) {
                    let hidden = Set(tabs.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
                    for closed in tabs {
                        checked += 1
                        let surviving = tabs.filter { $0 != closed }
                        let shown = Set(surviving).subtracting(hidden)
                        let pick = FocusAfterClose.tab(selected: closed, old: tabs, surviving: surviving, shown: shown, opener: opener)
                        let plain = FocusAfterClose.tab(selected: closed, old: tabs, surviving: surviving, shown: shown)
                        #expect((pick == nil) == surviving.isEmpty)
                        if let pick { #expect(surviving.contains(pick)) }
                        if !shown.isEmpty, let pick { #expect(shown.contains(pick)) }
                        if pick != plain, let pick {
                            let family = opener[pick] == closed || opener[closed] == pick
                                || (opener[pick] != nil && opener[pick] == opener[closed])
                            #expect(family)
                        }
                    }
                }
            }
        }
        #expect(checked > 1000)
    }

    /// Every assignment of an opener (or none) to each tab with no cycles.
    private static func forests(_ tabs: [String]) -> [[String: String]] {
        var result: [[String: String]] = [[:]]
        for tab in tabs {
            result = result.flatMap { map in
                [map] + tabs.filter { $0 != tab && !Self.reaches(map, from: $0, to: tab) }.map { map.merging([tab: $0]) { a, _ in a } }
            }
        }
        return result
    }

    private static func reaches(_ map: [String: String], from start: String, to target: String) -> Bool {
        var current: String? = start
        var steps = 0
        while let id = current, steps <= map.count {
            if id == target { return true }
            current = map[id]
            steps += 1
        }
        return false
    }
}
