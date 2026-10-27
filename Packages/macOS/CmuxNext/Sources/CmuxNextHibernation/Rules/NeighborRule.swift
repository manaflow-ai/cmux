// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The tab sits beside a pane's shown tab or was just hovered (`browser.keepNeighborTabsAwake`): it
    /// stays awake for an instant switch. The person's own Hibernate Tab still takes it.
    package static let neighbor = DiscardRule(.neighbor, result: .protected, for: DiscardRule.pressure,
                                              kinds: DiscardRule.browserPages) { candidate, _ in
        candidate.isNeighbor
    }
}
