// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// The page's site may show notifications: the timeout keeps it, memory pressure does not (Chrome's
    /// `kNotificationsEnabled`, proactive discards only).
    package static let notifications = DiscardRule(.notifications, result: .protected, for: [.proactive],
                                                   kinds: DiscardRule.browserPages) { candidate, _ in
        candidate.allowsNotifications
    }
}
