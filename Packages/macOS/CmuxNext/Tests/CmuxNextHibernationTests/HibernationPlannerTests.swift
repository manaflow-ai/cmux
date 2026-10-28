import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// The urgent pace A/B (p07-memory task 114): cmux's critical pace (3 pages every 3 s) against
/// Chrome's `UrgentPageDiscardingPolicy` (one page per critical event, then one every 5 s while it
/// lasts), measured as relief and wake churn on the real planner with 60 hidden tabs.
@Suite struct HibernationPlannerTests {
    typealias Planner = HibernationPlanner

    /// One run of ``urgentPaceTrial(_:needPages:lag:tabs:window:)``.
    nonisolated struct TrialResult: Equatable, Sendable {
        /// Seconds after the critical event when enough pages were gone; nil when not within the window.
        var reliefAt: Double?
        /// Pages discarded before critical pressure lifted or the window ended.
        var discarded: Int
        /// Pages discarded past the ones relief needed: each reloads (a wake) when the person shows it.
        var churn: Int?
    }

    /// Seconds after relief the kernel takes to lift critical pressure.
    nonisolated static let lags: [Double] = [1, 3, 5]

    /// `tabs` hidden 55 MB tabs (a hidden Chromium tab, p07-memory.md section 2) under critical
    /// pressure from t = 0, hidden 10 to 20 minutes. Critical lifts `lag` seconds after `needPages`
    /// pages are gone. The planner runs at the event and again at each `Plan.nextCheck`, as
    /// `BrowserHibernation.replan()` does, until the pressure lifts or `window` ends.
    nonisolated static func urgentPaceTrial(_ urgent: Planner.UrgentPace, needPages: Int, lag: Double,
                                            tabs: Int = 60, window: Double = 30) -> TrialResult {
        var hiddenAtStart = Dictionary(uniqueKeysWithValues: (0..<tabs).map { ("t\($0)", 600 + Double($0) * 10) })
        var now = 0.0
        var discarded = 0
        var reliefAt: Double?
        while now <= window, !hiddenAtStart.isEmpty {
            if let reliefAt, now >= reliefAt + lag { break }
            let candidates = hiddenAtStart.map { key, hidden in
                Planner.Candidate(key: key, hiddenFor: hidden + now, memoryBytes: 55 << 20)
            }
            let plan = Planner.plan(.fallback, pressure: .critical, urgent: urgent, candidates: candidates)
            for key in plan.due { hiddenAtStart[key] = nil }
            discarded += plan.due.count
            if reliefAt == nil, discarded >= needPages { reliefAt = now }
            guard let next = plan.nextCheck else { break }
            now += next
        }
        return TrialResult(reliefAt: reliefAt, discarded: discarded, churn: reliefAt.map { _ in discarded - needPages })
    }

    @Test func onlyCriticalPressureHasTwoPaces() {
        for urgent in Planner.UrgentPace.allCases {
            #expect(Planner.pace(at: .normal, urgent: urgent) == Planner.normalPace)
            #expect(Planner.pace(at: .warning, urgent: urgent) == Planner.warningPace)
        }
        let cmux = Planner.pace(at: .critical, urgent: .cmux)
        #expect(cmux == Planner.criticalPace)
        #expect(cmux == Planner.Pace(perPass: 3, interval: 3, minimumHidden: 10))
        let chrome = Planner.pace(at: .critical, urgent: .chrome)
        #expect(chrome == Planner.chromeCriticalPace)
        #expect(chrome == Planner.Pace(perPass: 1, interval: 5, minimumHidden: 10))
        #expect(chrome.interval == Planner.Pace.chromeUrgent.interval && chrome.perPass == Planner.Pace.chromeUrgent.perPass)
    }

    /// The A/B keeps the browser's pace, so every browser plan (and the golden table) stays the same.
    @Test func browsersKeepCmuxsPace() {
        #expect(Planner.UrgentPace.browsers == .cmux)
        let candidates = (0..<60).map { Planner.Candidate(key: "t\($0)", hiddenFor: 600 + Double($0) * 10) }
        for pressure: MemoryPressureLevel in [.normal, .warning, .critical] {
            #expect(Planner.pace(at: pressure) == Planner.pace(at: pressure, urgent: .cmux))
            #expect(Planner.plan(.fallback, pressure: pressure, candidates: candidates)
                == Planner.plan(.fallback, pressure: pressure, urgent: .cmux, candidates: candidates))
        }
    }

    @Test func chromesPaceTakesOnePagePerPassEveryFiveSeconds() {
        let candidates = (0..<60).map { Planner.Candidate(key: "t\($0)", hiddenFor: 600 + Double($0) * 10) }
        let plan = Planner.plan(.fallback, pressure: .critical, urgent: .chrome, candidates: candidates)
        #expect(plan.due == ["t59"], "the longest hidden goes first")
        #expect(plan.nextCheck == 5)
        let young = [Planner.Candidate(key: "just-left", hiddenFor: 9)]
        #expect(Planner.plan(.fallback, pressure: .critical, urgent: .chrome, candidates: young).due.isEmpty,
                "the browser's 10 s minimum hidden time holds for both paces")
    }

    /// Up to 7 pages (385 MB) both paces relieve within 30 s: Chrome's with no churn, cmux's sooner
    /// with up to 5 extra pages. Past that only cmux's relieves within 30 s; Chrome's stops at 7.
    @Test(arguments: HibernationPlannerTests.lags)
    func urgentPaceTrialAtSixtyTabs(lag: Double) {
        for need in 1...7 {
            let cmux = Self.urgentPaceTrial(.cmux, needPages: need, lag: lag)
            let chrome = Self.urgentPaceTrial(.chrome, needPages: need, lag: lag)
            #expect(cmux.reliefAt == Double((need + 2) / 3 - 1) * 3, "need \(need)")
            #expect(chrome.reliefAt == Double(need - 1) * 5, "need \(need)")
            #expect(chrome.churn == 0, "need \(need)")
            #expect((cmux.churn ?? -1) >= 0 && (cmux.churn ?? 6) <= 5, "need \(need)")
        }
        for need in [8, 10, 12, 15, 20, 30, 33] {
            let cmux = Self.urgentPaceTrial(.cmux, needPages: need, lag: lag)
            let chrome = Self.urgentPaceTrial(.chrome, needPages: need, lag: lag)
            #expect(cmux.reliefAt == Double((need + 2) / 3 - 1) * 3, "need \(need)")
            #expect(chrome.reliefAt == nil, "need \(need)")
            #expect(chrome.discarded == 7, "need \(need)")
        }
    }

    /// What each pace frees within 30 s when the pressure never lifts: 33 pages against 7.
    @Test func reliefCapacityWithinThirtySeconds() {
        #expect(Self.urgentPaceTrial(.cmux, needPages: 60, lag: 0) == TrialResult(reliefAt: nil, discarded: 33, churn: nil))
        #expect(Self.urgentPaceTrial(.chrome, needPages: 60, lag: 0) == TrialResult(reliefAt: nil, discarded: 7, churn: nil))
    }

    /// The rows of the p07-memory-114 commit table.
    @Test func urgentPaceTrialNumbers() {
        #expect(Self.urgentPaceTrial(.cmux, needPages: 1, lag: 1) == TrialResult(reliefAt: 0, discarded: 3, churn: 2))
        #expect(Self.urgentPaceTrial(.cmux, needPages: 1, lag: 5) == TrialResult(reliefAt: 0, discarded: 6, churn: 5))
        #expect(Self.urgentPaceTrial(.chrome, needPages: 1, lag: 5) == TrialResult(reliefAt: 0, discarded: 1, churn: 0))
        #expect(Self.urgentPaceTrial(.cmux, needPages: 3, lag: 3) == TrialResult(reliefAt: 0, discarded: 3, churn: 0))
        #expect(Self.urgentPaceTrial(.chrome, needPages: 3, lag: 3) == TrialResult(reliefAt: 10, discarded: 3, churn: 0))
        #expect(Self.urgentPaceTrial(.cmux, needPages: 7, lag: 5) == TrialResult(reliefAt: 6, discarded: 12, churn: 5))
        #expect(Self.urgentPaceTrial(.chrome, needPages: 7, lag: 5) == TrialResult(reliefAt: 30, discarded: 7, churn: 0))
        #expect(Self.urgentPaceTrial(.cmux, needPages: 12, lag: 1) == TrialResult(reliefAt: 9, discarded: 12, churn: 0))
        #expect(Self.urgentPaceTrial(.chrome, needPages: 12, lag: 1) == TrialResult(reliefAt: nil, discarded: 7, churn: nil))
        #expect(Self.urgentPaceTrial(.cmux, needPages: 30, lag: 5) == TrialResult(reliefAt: 27, discarded: 33, churn: 3))
    }
}
