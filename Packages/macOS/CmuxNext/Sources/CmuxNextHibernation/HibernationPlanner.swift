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

    /// Why a workspace's hibernation (plans/cmux-next/workspace-hibernation-DESIGN.md) keeps hidden page
    /// `candidate`, or nil when it may go: the rules that keep a page from the timeout (a pinned tab, an
    /// excluded site, DevTools, capture, a download, a form result, an agent lease, an engine that cannot
    /// restore it), with no wait for the timeout; hibernation off keeps every page.
    package static func workspaceRefusal(_ candidate: Candidate, setting: BrowserHibernationSetting) -> Exemption? {
        if !setting.isEnabled { return .disabled }
        return ContentDiscardPlanner().eligibility(of: candidate, setting: setting, for: .proactive).reason
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
    /// (`browser.hibernation`; 10 minutes at most under pressure) and pace (``pace(at:urgent:)``): a
    /// proactive plan without pressure, an urgent one with it. With hibernation off every page is
    /// kept, as disabled unless an earlier rule (a neighbor) keeps it.
    ///
    /// Without `discardsAutomatically` no page is due, at any memory pressure: a discarded page
    /// reloads when it wakes, which the person did not ask for. Each page is kept as
    /// ``CannotDiscardReason/keepsState`` unless an earlier rule keeps it.
    ///
    /// - Parameter urgent: The pace at critical pressure; browser pages use ``UrgentPace/browsers``.
    package static func plan(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel,
                             urgent: UrgentPace = .browsers, candidates: [Candidate]) -> Plan {
        let planner = ContentDiscardPlanner()
        let reason = discardReason(at: pressure)
        if setting.isEnabled, !setting.discardsAutomatically {
            var plan = Plan()
            for candidate in candidates {
                plan.exemptions[candidate.key] = planner.eligibility(of: candidate, setting: setting, for: reason).reason ?? .keepsState
            }
            return plan
        }
        guard let threshold = threshold(setting, pressure: pressure == .critical ? .warning : pressure) else {
            var plan = Plan()
            for candidate in candidates {
                plan.exemptions[candidate.key] = planner.eligibility(of: candidate, setting: setting, for: reason).reason ?? .disabled
            }
            return plan
        }
        return planner.plan(setting, for: reason, threshold: threshold, pace: pace(at: pressure, urgent: urgent), candidates: candidates)
    }

    /// The hidden browser pages the critical event's one urgent pass may take (``UrgentDiscardRanker``):
    /// hidden at least the critical pace's minimum, and nothing in the urgent eligibility keeps them
    /// (hibernation off keeps every page). A page the probe kept lately is protected, so it goes after
    /// the others, as in ``ContentDiscardPlanner/plan(_:for:threshold:pace:candidates:)``.
    package static func urgentCandidates(_ setting: BrowserHibernationSetting, candidates: [Candidate]) -> [UrgentDiscardRanker.Candidate] {
        // Without `discardsAutomatically` no page goes on its own, at any memory pressure (``plan(_:pressure:urgent:candidates:)``).
        guard !setting.isEnabled || setting.discardsAutomatically else { return [] }
        let planner = ContentDiscardPlanner()
        return candidates.compactMap { candidate in
            guard candidate.hiddenFor >= criticalPace.minimumHidden,
                  planner.eligibility(of: candidate, setting: setting, for: .urgent).reason == nil else { return nil }
            return UrgentDiscardRanker.Candidate(key: candidate.key, kind: candidate.kind, hiddenFor: candidate.hiddenFor,
                                                 estimatedBytes: candidate.memoryBytes, isProtected: candidate.recentlyKept)
        }
    }

    // The browser's own paces (p07-memory.md section 3.C). Other kinds use Chrome's
    // (`Pace.chromeUrgent`); at critical, browser pages keep cmux's (``UrgentPace/browsers``).

    /// Without pressure: two pages per pass, every 5 s while more are due.
    package static let normalPace = Pace(perPass: 2, interval: 5, minimumHidden: 0)
    /// At warning: one page hidden at least a minute, every 15 s.
    package static let warningPace = Pace(perPass: 1, interval: 15, minimumHidden: 60)
    /// At critical: three pages hidden at least 10 s, every 3 s.
    package static let criticalPace = Pace(perPass: 3, interval: 3, minimumHidden: 10)
    /// Chrome's urgent pace (``ContentDiscardPlanner/Pace/chromeUrgent``) with the browser's 10 s
    /// minimum hidden time, so the two critical paces differ only in how many pages go and how often.
    package static let chromeCriticalPace = Pace(perPass: Pace.chromeUrgent.perPass, interval: Pace.chromeUrgent.interval,
                                                 minimumHidden: criticalPace.minimumHidden)

    /// The two critical paces p07-memory task 114 measured. Only critical has two: Chrome does not
    /// discard at moderate pressure on macOS (`kSkipModerateMemoryPressureLevelMac`), and the
    /// browser's warning pace stays as it is.
    package nonisolated enum UrgentPace: String, CaseIterable, Hashable, Sendable {
        /// cmux's: three pages per pass, a pass every 3 s while critical lasts (``criticalPace``).
        case cmux
        /// Chrome's `UrgentPageDiscardingPolicy`
        /// (chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc): one page
        /// per critical event on macOS, then one every 5 s while it lasts (``chromeCriticalPace``).
        case chrome

        /// Browser pages keep cmux's pace. With 60 hidden 55 MB tabs at critical, Chrome's relieves
        /// at most 7 pages (385 MB) within 30 s and cmux's 33 (1815 MB); where both relieve, cmux's
        /// does it sooner (`HibernationPlannerTests`).
        package static let browsers = UrgentPace.cmux

        /// The pace of the passes at critical pressure.
        package var pace: Pace {
            switch self {
            case .cmux: HibernationPlanner.criticalPace
            case .chrome: HibernationPlanner.chromeCriticalPace
            }
        }
    }

    /// The browser's pace at `pressure`; `urgent` picks the one at critical.
    package static func pace(at pressure: MemoryPressureLevel, urgent: UrgentPace = .browsers) -> Pace {
        switch pressure {
        case .normal: normalPace
        case .warning: warningPace
        case .critical: urgent.pace
        }
    }
}
