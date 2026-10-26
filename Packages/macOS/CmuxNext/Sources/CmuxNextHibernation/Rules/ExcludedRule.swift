// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

import CmuxNextSettings

nonisolated extension DiscardRule {
    /// The page's host is in `browser.hibernationExclusions` (Never Hibernate This Site; Chrome's
    /// `kOptedOut`).
    package static let excluded = DiscardRule(.excluded, result: .protected, for: DiscardRule.pressure) { candidate, context in
        context.setting.excludes(host: candidate.host)
    }
}
