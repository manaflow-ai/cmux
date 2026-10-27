// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

import CmuxNextSettings

nonisolated extension DiscardRule {
    /// A pinned tab, unless `browser.hibernatePinnedTabs` lets pinned tabs go (Chrome's `kPinnedTab`).
    package static let pinned = DiscardRule(.pinned, result: .protected, for: DiscardRule.automatic,
                                            kinds: DiscardRule.browserPages) { candidate, context in
        candidate.isPinned && !context.browser.includesPinnedTabs
    }
}
