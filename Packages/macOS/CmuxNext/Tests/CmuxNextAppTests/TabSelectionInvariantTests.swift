import CmuxNextBridge
import Testing

/// The pane selection invariant (plans/cmux-next/pane-active-tab-DESIGN.md):
/// whenever a pane has tabs, `TabSelectionMemory.resolve` names exactly one
/// of them, and a shown one whenever any tab is shown. The daemon's default
/// is a tab id, never an index into a list of another shape.
@MainActor
@Suite struct TabSelectionInvariantTests {
    /// Repro: the selected tab's group collapses from outside this window
    /// (CLI `cmux tab group <g> update --collapse`, MCP, another window).
    /// The strip hides every member, so the pane showed no active tab while
    /// its content still showed the hidden one.
    @Test func groupCollapsedElsewhereMovesSelectionToAShownTab() {
        let memory = TabSelectionMemory()
        let tabs = ["a", "b", "c", "d"]
        #expect(memory.resolve(pane: "p", tabs: tabs, defaultTab: "a") == "a")
        memory.select("b", in: "p")
        #expect(memory.resolve(pane: "p", tabs: tabs, defaultTab: "a") == "b")
        // b and c collapse: the next shown tab after b is d.
        #expect(memory.resolve(pane: "p", tabs: tabs, defaultTab: "a", hidden: ["b", "c"]) == "d")
    }

    /// Repro: an explicit selection of a member of a collapsed group (palette,
    /// search, Cmd-digit, a reveal) stays selected; the pane expands that
    /// group in the daemon (the strip's own expansion was overwritten by
    /// the daemon's next snapshot, hiding the selected tab again).
    @Test func explicitSelectionIntoACollapsedGroupStays() {
        let memory = TabSelectionMemory()
        let tabs = ["a", "b", "c", "d"]
        #expect(memory.resolve(pane: "p", tabs: tabs, defaultTab: "a", hidden: ["b", "c"]) == "a")
        memory.select("c", in: "p")
        #expect(memory.resolve(pane: "p", tabs: tabs, defaultTab: "a", hidden: ["b", "c"]) == "c")
        // Until the expansion lands the selection holds; it does not bounce out.
        #expect(memory.resolve(pane: "p", tabs: tabs, defaultTab: "a", hidden: ["b", "c"]) == "c")
        // Once shown and then collapsed again (from anywhere), it moves out.
        #expect(memory.resolve(pane: "p", tabs: tabs, defaultTab: "a") == "c")
        #expect(memory.resolve(pane: "p", tabs: tabs, defaultTab: "a", hidden: ["b", "c"]) == "d")
    }

    /// When every tab is hidden the selection stays (the strip expands its group).
    @Test func allHiddenKeepsTheSelection() {
        let memory = TabSelectionMemory()
        memory.select("b", in: "p")
        #expect(memory.resolve(pane: "p", tabs: ["a", "b"], defaultTab: "a", hidden: ["a", "b"]) == "b")
    }

    /// Repro: the daemon's default is an index into its own tab list, but
    /// the strip's list leaves out dock-bound tabs and appends local ones,
    /// so the index named the wrong tab. The default is now the tab id.
    @Test func defaultIsTheDaemonsTabNotAnIndexIntoAnotherList() {
        let memory = TabSelectionMemory()
        // Daemon tabs [docked, x, y] with active index 2 (y); the strip shows [x, y, local].
        #expect(memory.resolve(pane: "p", tabs: ["x", "y", "local"], defaultTab: "y") == "y")
        // A default the strip does not show falls back to the first shown tab.
        let other = TabSelectionMemory()
        #expect(other.resolve(pane: "q", tabs: ["x", "y"], defaultTab: "docked", hidden: ["x"]) == "y")
    }

    /// A selection of a tab that is not in the pane (a stale window record,
    /// a reveal racing a move) never sticks: the pane shows its default.
    @Test func foreignSelectionResolvesToAPaneTab() {
        let memory = TabSelectionMemory()
        memory.select("elsewhere", in: "p")
        #expect(memory.resolve(pane: "p", tabs: ["a", "b"], defaultTab: "b") == "b")
        #expect(memory.selection(in: "p") == "b")
    }

    /// Property: random tab lists, hides, selections (including foreign
    /// ids), defaults and prunes. After every resolve the result is nil only
    /// for an empty pane, is one of the pane's tabs, is shown when any tab
    /// is shown, and is what the memory reports.
    @Test(arguments: 1...64) func resolveIsTotalUnderRandomOps(seed: Int) {
        var rng = SplitMix(seed: UInt64(seed))
        let memory = TabSelectionMemory()
        var panes: [String: [String]] = ["p0": ["t0"], "p1": ["t1", "t2"]]
        var hidden: [String: Set<String>] = [:]
        var next = 3
        // Explicit selections of a hidden tab: held (and expanded by the pane) until shown once.
        var pendingExpand: [String: String] = [:]
        for step in 0..<200 {
            let pane = "p\(rng.below(3))"
            var tabs = panes[pane] ?? []
            switch rng.below(8) {
            case 0, 1:
                tabs.insert("t\(next)", at: rng.below(tabs.count + 1)); next += 1
            case 2:
                if !tabs.isEmpty { tabs.remove(at: rng.below(tabs.count)) }
            case 3:
                if tabs.count > 1 { tabs.insert(tabs.remove(at: rng.below(tabs.count)), at: rng.below(tabs.count)) }
            case 4:
                hidden[pane] = Set(tabs.filter { _ in rng.below(3) == 0 })
            case 5:
                hidden[pane] = []
            case 6:
                let all = panes.values.flatMap { $0 } + ["ghost"]
                let chosen = all[rng.below(all.count)]
                memory.select(chosen, in: pane)
                pendingExpand[pane] = chosen
            default:
                if rng.below(4) == 0 { memory.prune(livePanes: Set(panes.keys.filter { $0 != pane })) }
            }
            panes[pane] = tabs
            let shown = tabs.filter { !(hidden[pane] ?? []).contains($0) }
            let defaultTab = rng.below(4) == 0 ? "ghost" : tabs.isEmpty ? nil : tabs[rng.below(tabs.count)]
            let picked = memory.resolve(pane: pane, tabs: tabs, defaultTab: defaultTab, hidden: hidden[pane] ?? [])
            let context = "seed \(seed) step \(step) pane \(pane) tabs \(tabs) hidden \(hidden[pane] ?? []) picked \(picked ?? "nil")"
            if tabs.isEmpty {
                #expect(picked == nil, "\(context)")
                continue
            }
            #expect(picked.map(tabs.contains) == true, "I2: selection is one of the pane's tabs: \(context)")
            if let picked, shown.contains(picked) || pendingExpand[pane] != picked { pendingExpand[pane] = nil }
            if !shown.isEmpty, pendingExpand[pane] == nil {
                #expect(picked.map(shown.contains) == true, "I5: selection is shown: \(context)")
            }
            #expect(memory.selection(in: pane) == picked, "selection memory agrees: \(context)")
        }
    }
}

/// A deterministic generator, so a failing seed replays.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}
