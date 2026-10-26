import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// The urgent pace A/B (p07-memory-114): cmux's critical pace (3 pages per 3 s) against Chrome's
/// `UrgentPageDiscardingPolicy` (one page per critical event, one more every 5 s while it lasts).
@Suite struct HibernationPlannerTests {
    typealias Planner = HibernationPlanner

    /// One run of `urgentPaceTrial`.
    struct TrialResult: Equatable {
        /// Seconds after the critical event when enough pages were gone; nil when not within the window.
        var reliefAt: Double?
        /// Pages discarded before critical pressure lifted or the window ended.
        var discarded: Int
        /// Pages discarded past the ones relief needed: each reloads when the person shows it.
        var churn: Int?
    }

    /// `tabs` hidden 55 MB tabs (a hidden Chromium tab, p07-memory.md) under critical pressure from
    /// t = 0. The kernel lifts critical `lag` seconds after `needPages` pages are gone. The real
    /// planner runs at the event and again at each `Plan.nextCheck`, as `BrowserHibernation` does.
    static func urgentPaceTrial(_ urgent: Planner.UrgentPace, needPages: Int, lag: Double,
                                tabs: Int = 60, window: Double = 30) -> TrialResult {
        // Hidden 10 to 20 minutes: past the 10 minute timeout under pressure, short of the 30 minute one.
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
        for urgent: Planner.UrgentPace in [.cmux, .chrome] {
            #expect(Planner.Pace.at(.normal, urgent: urgent) == .normal)
            #expect(Planner.Pace.at(.warning, urgent: urgent) == .warning)
        }
        let cmux = Planner.Pace.at(.critical, urgent: .cmux)
        #expect(cmux == .critical)
        #expect([cmux.perPass, Int(cmux.interval), Int(cmux.minimumHidden)] == [3, 3, 10])
        let chrome = Planner.Pace.at(.critical, urgent: .chrome)
        #expect(chrome == .chromeCritical)
        #expect([chrome.perPass, Int(chrome.interval), Int(chrome.minimumHidden)] == [1, 5, 10])
    }

    /// The A/B keeps the browser's pace, so every browser plan stays the same; new kinds start on Chrome's.
    @Test func browsersKeepTheirPaceAndNewKindsTakeChromes() {
        #expect(Planner.UrgentPace.forBrowsers == .cmux)
        #expect(Planner.UrgentPace.forNewKinds == .chrome)
        let candidates = (0..<60).map { Planner.Candidate(key: "t\($0)", hiddenFor: 600 + Double($0) * 10) }
        for pressure: MemoryPressureLevel in [.normal, .warning, .critical] {
            #expect(Planner.plan(.fallback, pressure: pressure, candidates: candidates)
                == Planner.plan(.fallback, pressure: pressure, urgent: .cmux, candidates: candidates))
        }
    }

    @Test func chromesPaceTakesOnePagePerPassEveryFiveSeconds() {
        let candidates = (0..<60).map { Planner.Candidate(key: "t\($0)", hiddenFor: 600 + Double($0) * 10) }
        let plan = Planner.plan(.fallback, pressure: .critical, urgent: .chrome, candidates: candidates)
        #expect(plan.due == ["t59"], "the longest hidden goes first")
        #expect(plan.nextCheck == 5)
    }

    /// At 60 tabs Chrome's pace relieves within 30 s only up to 7 pages (385 MB); there it has no
    /// churn and cmux's has up to 5 pages. Past 7 pages only cmux's pace relieves within 30 s.
    @Test(arguments: [1.0, 3.0, 5.0])
    func urgentPaceTrialAtSixtyTabs(lag: Double) {
        for need in [1, 2, 3, 4, 5, 6, 7] {
            let cmux = Self.urgentPaceTrial(.cmux, needPages: need, lag: lag)
            let chrome = Self.urgentPaceTrial(.chrome, needPages: need, lag: lag)
            #expect(cmux.reliefAt.map { $0 <= 30 } == true)
            #expect(chrome.reliefAt == Double(need - 1) * 5)
            #expect(chrome.churn == 0)
            #expect((cmux.churn ?? 0) >= (chrome.churn ?? 0))
        }
        for need in [8, 10, 12, 15, 20, 30] {
            let cmux = Self.urgentPaceTrial(.cmux, needPages: need, lag: lag)
            let chrome = Self.urgentPaceTrial(.chrome, needPages: need, lag: lag)
            #expect(cmux.reliefAt == Double((need + 2) / 3 - 1) * 3)
            #expect(chrome.reliefAt == nil)
            #expect(chrome.discarded == 7)
        }
    }

    /// The numbers in the p07-memory-114 commit.
    @Test func urgentPaceTrialNumbers() {
        #expect(Self.urgentPaceTrial(.cmux, needPages: 1, lag: 5) == TrialResult(reliefAt: 0, discarded: 6, churn: 5))
        #expect(Self.urgentPaceTrial(.chrome, needPages: 1, lag: 5) == TrialResult(reliefAt: 0, discarded: 1, churn: 0))
        #expect(Self.urgentPaceTrial(.cmux, needPages: 7, lag: 1) == TrialResult(reliefAt: 6, discarded: 9, churn: 2))
        #expect(Self.urgentPaceTrial(.chrome, needPages: 7, lag: 1) == TrialResult(reliefAt: 30, discarded: 7, churn: 0))
        #expect(Self.urgentPaceTrial(.cmux, needPages: 30, lag: 1) == TrialResult(reliefAt: 27, discarded: 30, churn: 0))
        #expect(Self.urgentPaceTrial(.chrome, needPages: 30, lag: 1) == TrialResult(reliefAt: nil, discarded: 7, churn: nil))
    }
}
