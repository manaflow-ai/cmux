@testable import CmuxNextApp
import CmuxNextHibernation
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextSettings
import Foundation
import Testing

/// Smarter tab hibernation (user msg 9103): the planner used to hibernate every hidden page past
/// one age threshold, and under critical memory pressure every eligible page at once. It now
/// ranks pages by value (how long hidden, how often the person comes back to them, how much
/// memory they hold), hibernates the least valuable first, a few per pass, and only after the
/// idle timeout (30 minutes by default) or under memory pressure.
@Suite struct HibernationRankingTests {
    private func page(_ key: String, minutes: Double, focus: Int = 0, megabytes: UInt64? = nil,
                      downloading: Bool = false, lease: Bool = false) -> HibernationPlanner.Candidate {
        var candidate = HibernationPlanner.Candidate(key: key, hiddenFor: minutes * 60)
        candidate.recentFocusCount = focus
        candidate.memoryBytes = megabytes.map { $0 << 20 }
        candidate.isDownloading = downloading
        candidate.hasAgentLease = lease
        return candidate
    }

    @Test func theDefaultIdleTimeoutIsThirtyMinutes() {
        #expect(BrowserHibernationSetting.fallback.hiddenMinutes == 30)
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .normal, candidates: [
            page("old", minutes: 31), page("young", minutes: 29),
        ])
        #expect(plan.due == ["old"])
        #expect(plan.nextCheck.map { abs($0 - 60) < 1e-6 } == true)
    }

    /// Fifty tabs past the timeout do not all close in one pass: a few go, then the next pass.
    @Test func neverAllAtOnce() {
        let candidates = (0..<50).map { page("t\($0)", minutes: 40 + Double($0)) }
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .normal, candidates: candidates)
        #expect(plan.due.count == HibernationPlanner.Pace.normal.perPass)
        #expect(plan.due == ["t49", "t48"], "the longest idle go first")
        #expect(plan.nextCheck == HibernationPlanner.Pace.normal.interval)
    }

    @Test func criticalPressureStillGoesInBatches() {
        let candidates = (0..<20).map { page("t\($0)", minutes: 2 + Double($0)) }
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .critical, candidates: candidates)
        #expect(plan.due.count == HibernationPlanner.Pace.critical.perPass)
        #expect(plan.nextCheck == HibernationPlanner.Pace.critical.interval)
    }

    /// A tab the person keeps coming back to outlives one they opened once, hidden as long.
    @Test func frequentlyFocusedTabsHibernateLater() {
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .normal, candidates: [
            page("once", minutes: 36, focus: 1), page("often", minutes: 35, focus: 15),
        ])
        #expect(plan.due == ["once"])
    }

    /// Under pressure, the page that frees the most memory for the least loss goes first.
    @Test func underPressureTheHeaviestOfEqualPagesGoesFirst() {
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .warning, candidates: [
            page("light", minutes: 5, megabytes: 80), page("heavy", minutes: 5, megabytes: 900),
            page("medium", minutes: 5, megabytes: 300),
        ])
        #expect(plan.due == ["heavy"])
    }

    /// Memory pressure relieves itself one page at a time even when none reached the timeout,
    /// and never takes a page the person just left.
    @Test func warningPressureRelievesOnePageAtATime() {
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .warning, candidates: [
            page("just-left", minutes: 0.2, megabytes: 2_000), page("a", minutes: 3), page("b", minutes: 6),
        ])
        #expect(plan.due == ["b"])
        #expect(plan.nextCheck == HibernationPlanner.Pace.warning.interval)
    }

    /// Without pressure, nothing goes before its timeout, however heavy.
    @Test func noPressureNoEarlyHibernation() {
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .normal, candidates: [page("heavy", minutes: 10, megabytes: 4_000)])
        #expect(plan.due.isEmpty)
    }

    /// Under pressure a page the probe just kept (it played) goes after the others, so it does
    /// not hold up the relief; alone, it is asked again.
    @Test func aRecentlyKeptPageDoesNotBlockRelief() {
        var playing = page("playing", minutes: 20)
        playing.recentlyKept = true
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .warning, candidates: [playing, page("quiet", minutes: 5)])
        #expect(plan.due == ["quiet"])
        #expect(HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .warning, candidates: [playing]).due == ["playing"])
    }

    @Test func downloadsAndAgentLeasesNeverHibernate() {
        for pressure in [MemoryPressureLevel.normal, .warning, .critical] {
            let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: pressure, candidates: [
                page("dl", minutes: 500, downloading: true), page("agent", minutes: 500, lease: true),
            ])
            #expect(plan.due.isEmpty, "\(pressure)")
            #expect(plan.exemptions["dl"] == .downloading)
            #expect(plan.exemptions["agent"] == .agentLease)
        }
    }

    /// An agent's leased page does not freeze either: its next call would wait on a thaw.
    @Test func leasedPagesDoNotFreeze() {
        let plan = HibernationPlanner.freezePlan(.fallback, candidates: [page("agent", minutes: 5, lease: true)])
        #expect(plan.due.isEmpty)
    }

    /// "Never Hibernate This Site" adds the page's host once.
    @Test func neverHibernateSiteAddsTheHostOnce() {
        var setting = BrowserHibernationSetting.fallback
        setting.exclusions = ["mail.google.com"]
        #expect(setting.addingExclusion(host: "Docs.Example.com").exclusions == ["mail.google.com", "docs.example.com"])
        #expect(setting.addingExclusion(host: "inbox.mail.google.com").exclusions == ["mail.google.com"])
        #expect(setting.addingExclusion(host: nil).exclusions == ["mail.google.com"])
    }
}
