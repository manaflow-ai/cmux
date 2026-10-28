// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

import CmuxNextSettings

nonisolated extension DiscardRule {
    /// `browser.hibernation` is off: nothing goes for the timeout, memory pressure, a frozen page's
    /// memory growth or a crashed subframe. The person's own Hibernate Tab still works (Chrome's opt-out is a protection too).
    package static let disabled = DiscardRule(.disabled, result: .protected, for: DiscardRule.automatic,
                                              kinds: DiscardRule.browserPages) { _, context in
        !context.browser.isEnabled
    }
}
