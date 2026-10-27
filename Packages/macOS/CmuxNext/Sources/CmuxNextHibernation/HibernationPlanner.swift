package import CmuxNextCompat
package import CmuxNextSettings

/// Which hidden pages hibernate now, and when to look again
/// (plans/cmux-next/tab-lifecycle.md). Pure: the App feeds it facts and a
/// clock reading; `BrowserHibernation` performs the result.
///
/// The browser's side of ``ContentDiscardPlanner``: it picks the browser's timeout and pace for
/// the memory pressure and hands the rest to the planner, which every kind of content shares.
package nonisolated struct HibernationPlanner: Sendable {
    package init() {}

    /// One hidden page that could hibernate (a ``ContentDiscardPlanner/Candidate`` of kind browser).
    package typealias Candidate = ContentDiscardPlanner.Candidate
    /// How many pages one pass hibernates and how soon the next pass runs while more are due,
    /// so pages never all close at once (a page that wakes meanwhile drops out of the queue).
    package typealias Pace = ContentDiscardPlanner.Pace
    /// Why a page does not hibernate (reported by `debug.surfaces` by its raw value).
    package typealias Exemption = CannotDiscardReason
    package typealias Plan = ContentDiscardPlanner.Plan

    /// The discard reason of a browser plan at `pressure`: the timeout without pressure, urgent
    /// with it.
    package static func discardReason(at pressure: MemoryPressureLevel) -> DiscardReason {
        pressure == .normal ? .proactive : .urgent
    }

    /// Seconds hidden before a page hibernates; nil means never.
    package static func threshold(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) -> Double? {
        guard let minutes = setting.hiddenMinutes else { return nil }
        switch pressure {
        case .normal: return minutes * 60
        case .warning: return setting.mode == .aggressive ? 0 : min(minutes, 10) * 60
        case .critical: return 0
        }
    }

    /// Why the person's Hibernate Tab refuses hidden page `candidate`, or nil when it may go: Chrome's
    /// external discard, which only a ``CanDiscardResult/disallowed`` rule stops.
    package static func hibernateTabRefusal(_ candidate: Candidate, setting: BrowserHibernationSetting) -> Exemption? {
        ContentDiscardPlanner().eligibility(of: candidate, setting: setting, for: .external).reason
    }

    /// The share of the timeout each doubling of recent focus buys
    /// (``ContentDiscardPlanner/focusCreditPerDoubling``).
    package static let focusCreditPerDoubling = ContentDiscardPlanner.focusCreditPerDoubling

    /// Seconds a page's memory counts as extra idleness under memory pressure
    /// (``ContentDiscardPlanner/memoryCredit(_:)``).
    package static func memoryCredit(_ bytes: UInt64?) -> Double {
        ContentDiscardPlanner.memoryCredit(bytes)
    }

    /// How idle a page counts as at `pressure` (``ContentDiscardPlanner/idleness(_:for:timeout:)``).
    package static func idleness(_ candidate: Candidate, pressure: MemoryPressureLevel, timeout: Double) -> Double {
        ContentDiscardPlanner.idleness(candidate, for: discardReason(at: pressure), timeout: timeout)
    }

    /// The pages to hibernate now, least valuable first, and when to look again.
    ///
    /// ``ContentDiscardPlanner/plan(_:for:threshold:pace:candidates:)`` with the browser's timeout
    /// (`browser.hibernation`; 10 minutes at most under pressure) and pace (``pace(at:)``): a
    /// proactive plan without pressure, an urgent one with it. With hibernation off every page is
    /// kept, as disabled unless an earlier rule (a neighbor) keeps it.
    package static func plan(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel, candidates: [Candidate]) -> Plan {
        let planner = ContentDiscardPlanner()
        let reason = discardReason(at: pressure)
        guard let threshold = threshold(setting, pressure: pressure == .critical ? .warning : pressure) else {
            var plan = Plan()
            for candidate in candidates {
                plan.exemptions[candidate.key] = planner.eligibility(of: candidate, setting: setting, for: reason).reason ?? .disabled
            }
            return plan
        }
        return planner.plan(setting, for: reason, threshold: threshold, pace: pace(at: pressure), candidates: candidates)
    }

    /// The hidden browser pages the critical event's one urgent pass may take (``UrgentDiscardRanker``):
    /// hidden at least the critical pace's minimum, and nothing in the urgent eligibility keeps them
    /// (hibernation off keeps every page). A page the probe kept lately is protected, so it goes after
    /// the others, as in ``ContentDiscardPlanner/plan(_:for:threshold:pace:candidates:)``.
    package static func urgentCandidates(_ setting: BrowserHibernationSetting, candidates: [Candidate]) -> [UrgentDiscardRanker.Candidate] {
        let planner = ContentDiscardPlanner()
        return candidates.compactMap { candidate in
            guard candidate.hiddenFor >= criticalPace.minimumHidden,
                  planner.eligibility(of: candidate, setting: setting, for: .urgent).reason == nil else { return nil }
            return UrgentDiscardRanker.Candidate(key: candidate.key, kind: candidate.kind, hiddenFor: candidate.hiddenFor,
                                                 estimatedBytes: candidate.memoryBytes, isProtected: candidate.recentlyKept)
        }
    }

    // The browser's own paces. Other kinds use Chrome's (`Pace.chromeUrgent`); these stay for
    // browser pages until task 114 measures both (p07-memory.md section 3.C).

    /// Without pressure: two pages per pass, every 5 s while more are due.
    package static let normalPace = Pace(perPass: 2, interval: 5, minimumHidden: 0)
    /// At warning: one page hidden at least a minute, every 15 s.
    package static let warningPace = Pace(perPass: 1, interval: 15, minimumHidden: 60)
    /// At critical: three pages hidden at least 10 s, every 3 s.
    package static let criticalPace = Pace(perPass: 3, interval: 3, minimumHidden: 10)

    /// The browser's pace at `pressure`.
    package static func pace(at pressure: MemoryPressureLevel) -> Pace {
        switch pressure {
        case .normal: normalPace
        case .warning: warningPace
        case .critical: criticalPace
        }
    }
}
