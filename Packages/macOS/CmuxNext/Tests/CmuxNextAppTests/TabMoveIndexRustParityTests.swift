import CmuxNextBridge
import CmuxNextAppCore
import Testing

struct TabMoveIndexRustParityTests {
    @Test func wireIndexMatchesOriginalIncludingSignedExtremes() {
        let indices = Array(-8...12) + [Int.min, Int.max]
        let currents: [Int?] = [nil] + indices.map { Optional($0) }
        for final in indices {
            for current in currents {
                // The old implementation traps on Int.max + 1; it has no result to compare.
                if final == Int.max, let current, final > current { continue }
                #expect(TabMoveIndex.wireIndex(finalIndex: final, currentIndex: current)
                    == OriginalTabMoveIndex.wireIndex(finalIndex: final, currentIndex: current))
            }
        }
    }

    @Test func paneIndexMatchesOriginalReorderingHiddenAndDuplicateTabs() {
        for display in Self.sequences {
            for pane in Self.sequences {
                for moving in Self.movingIDs {
                    for index in Self.indices {
                        #expect(TabMoveIndex.paneFinalIndex(display: display, moving: moving, displayIndex: index, pane: pane)
                            == OriginalTabMoveIndex.paneFinalIndex(display: display, moving: moving, displayIndex: index, pane: pane))
                    }
                }
            }
        }
    }

    @Test func groupIndexMatchesOriginalForEveryMembershipSubset() {
        let possibleMembers = ["a", "b", "hidden", "", "é", "a\u{0}b", "c", "😀"]
        for display in Self.sequences {
            for mask in 0..<(1 << possibleMembers.count) {
                let members = Set(possibleMembers.enumerated().compactMap { index, value in
                    mask & (1 << index) != 0 ? value : nil
                })
                for moving in Self.movingIDs {
                    for index in Self.indices {
                        #expect(TabMoveIndex.groupIndex(display: display, members: members, moving: moving, displayIndex: index)
                            == OriginalTabMoveIndex.groupIndex(display: display, members: members, moving: moving, displayIndex: index))
                    }
                }
            }
        }
    }

    @Test func canonicalUnicodeAndEmbeddedNULUseSwiftEqualityAcrossBuffers() {
        let composed = "é"
        let decomposed = "e\u{301}"
        #expect(composed == decomposed)
        let forms = [composed, decomposed, "a\u{0}b", "a", "\u{0}", "", "😀"]
        for moving in forms {
            for index in Self.indices {
                let display = [decomposed, "a\u{0}b", "a", composed, "\u{0}", "", "😀"]
                let pane = ["", composed, "hidden", "a", "a\u{0}b", decomposed, "\u{0}", "😀"]
                let members: Set<String> = [composed, "a\u{0}b", "\u{0}", "😀"]
                #expect(TabMoveIndex.paneFinalIndex(display: display, moving: moving, displayIndex: index, pane: pane)
                    == OriginalTabMoveIndex.paneFinalIndex(display: display, moving: moving, displayIndex: index, pane: pane))
                #expect(TabMoveIndex.groupIndex(display: display, members: members, moving: moving, displayIndex: index)
                    == OriginalTabMoveIndex.groupIndex(display: display, members: members, moving: moving, displayIndex: index))
                // Canonically equivalent strings appear only in the other buffer too.
                #expect(TabMoveIndex.paneFinalIndex(display: ["a", decomposed], moving: moving, displayIndex: index, pane: [composed, "a"])
                    == OriginalTabMoveIndex.paneFinalIndex(display: ["a", decomposed], moving: moving, displayIndex: index, pane: [composed, "a"]))
                #expect(TabMoveIndex.groupIndex(display: [decomposed, "a"], members: [composed], moving: moving, displayIndex: index)
                    == OriginalTabMoveIndex.groupIndex(display: [decomposed, "a"], members: [composed], moving: moving, displayIndex: index))
            }
        }
    }

    private static var indices: [Int] { [Int.min, -3, -1, 0, 1, 2, 3, 6, Int.max] }
    private static var movingIDs: [String] { ["a", "b", "c", "missing", "", "é", "a\u{0}b", "😀"] }
    private static var sequences: [[String]] {
        [[], ["a"], ["a", "b", "c"], ["c", "b", "a"], ["b", "a", "c"],
         ["a", "a"], ["b", "a", "b"], ["hidden", "a", "c"], ["", "a", ""],
         ["é", "😀", "a\u{0}b"], ["e\u{301}", "a", "é"], ["a", "a\u{0}b", "\u{0}"]]
    }
}

// Frozen original from 448f224569597f865aeeda2896f7d34a34215e4e, before the Rust port.
// Only visibility and the enum name changed; all three policy bodies are copied verbatim.
/// Index conversions for the daemon's `move-tab`.
private nonisolated enum OriginalTabMoveIndex {
    /// The wire index for moving a tab to `finalIndex` (its position after
    /// the move). `move-tab` takes insertion coordinates in the pre-move
    /// list: for a same-pane move the daemon removes the tab first and
    /// subtracts one from an index past it (cmux-tui spec "move-tab").
    /// `currentIndex` is the tab's index when it is already in the
    /// destination pane, else nil (cross-pane moves use the final index).
    static func wireIndex(finalIndex: Int, currentIndex: Int?) -> Int {
        guard let currentIndex, finalIndex > currentIndex else { return max(0, finalIndex) }
        return finalIndex + 1
    }

    /// The final index in the pane's own (daemon) order for a strip drop
    /// that puts `moving` at `displayIndex` of the strip's display order.
    /// The strip shows pinned tabs first, group members together, closing
    /// tabs hidden and app-local tabs last, so a display index is not a
    /// pane index. The tab goes right before the pane tab that follows it
    /// in the new display order, else last.
    static func paneFinalIndex(display: [String], moving: String, displayIndex: Int, pane: [String]) -> Int {
        var shown = display.filter { $0 != moving }
        shown.insert(moving, at: min(max(displayIndex, 0), shown.count))
        let others = pane.filter { $0 != moving }
        let after = shown.drop { $0 != moving }.dropFirst()
        return after.lazy.compactMap { others.firstIndex(of: $0) }.first ?? others.count
    }

    /// The position inside `group` for a strip drop that puts `moving` at
    /// `displayIndex` of the strip's display order: the members of `group`
    /// shown before it. `add-tabs-to-group` takes a position inside the
    /// group, the strip reports a display index.
    static func groupIndex(display: [String], members: Set<String>, moving: String, displayIndex: Int) -> Int {
        let shown = display.filter { $0 != moving }
        return shown.prefix(min(max(displayIndex, 0), shown.count)).filter(members.contains).count
    }
}
