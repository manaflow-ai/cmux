// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// DevTools are open on the page (Chrome's `kDevToolsOpen`).
    package static let devTools = DiscardRule(.devTools, result: .protected, for: DiscardRule.automatic) { candidate, _ in
        candidate.hasDevTools
    }
}
