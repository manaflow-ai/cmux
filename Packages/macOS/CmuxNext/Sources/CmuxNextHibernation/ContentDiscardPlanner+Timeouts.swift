package import CmuxNextSettings

nonisolated extension ContentDiscardPlanner {
    /// Hidden content with the timeout of its own ``ContentDiscardPolicy`` (page tabs: each
    /// provider's).
    package nonisolated struct TimedCandidate: Hashable, Sendable {
        package var candidate: Candidate
        /// Seconds hidden before it is due.
        package var timeout: Double

        package init(_ candidate: Candidate, timeout: Double) {
            self.candidate = candidate
            self.timeout = timeout
        }
    }

    /// ``plan(_:for:threshold:pace:candidates:)`` for candidates whose timeouts differ: each
    /// timeout's candidates plan against it, the most overdue go first, at most `pace.perPass` in
    /// all, and the next look is the soonest any of them asks for.
    ///
    /// - Parameters:
    ///   - setting: `browser.hibernation`, read by the rules of browser pages.
    ///   - reason: ``DiscardReason/proactive`` without pressure, ``DiscardReason/urgent`` with it.
    ///   - pace: How many go per pass and how often.
    ///   - timed: The hidden content, each with its timeout.
    /// - Returns: The due keys, the next check and each kept candidate's reason.
    package func plan(_ setting: BrowserHibernationSetting, for reason: DiscardReason, pace: Pace,
                      timed: [TimedCandidate]) -> Plan {
        var merged = Plan()
        var due: [(key: String, overdue: Double)] = []
        for (timeout, group) in Dictionary(grouping: timed, by: \.timeout) {
            let part = self.plan(setting, for: reason, threshold: timeout, pace: pace, candidates: group.map(\.candidate))
            let hidden = Dictionary(group.map { ($0.candidate.key, $0.candidate.hiddenFor) }, uniquingKeysWith: { first, _ in first })
            for key in part.due { due.append((key: key, overdue: (hidden[key] ?? 0) - timeout)) }
            merged.exemptions.merge(part.exemptions) { first, _ in first }
            if let check = part.nextCheck { merged.nextCheck = min(merged.nextCheck ?? .infinity, check) }
        }
        due.sort { $0.overdue != $1.overdue ? $0.overdue > $1.overdue : $0.key < $1.key }
        merged.due = due.prefix(pace.perPass).map(\.key)
        if due.count > merged.due.count { merged.nextCheck = min(merged.nextCheck ?? .infinity, pace.interval) }
        return merged
    }
}
