@testable import CmuxNextApp
import CmuxNextHibernation
import CmuxNextCompat
@testable import CmuxNextSettings
import Foundation
import Testing

/// The ranking and pacing of hidden tab discards are Rust (cmux-tui/crates/cmux-tab-discard, whose
/// tests cover them: the timeout, never all at once, batches under pressure, focus credit, memory
/// under pressure, the probe's recent keeps, downloads and agent leases). These check the app's
/// facts reach the rules intact and the setting's own helpers.
@Suite struct HibernationRankingTests {
    /// The candidate's facts cross the FFI by name: the longest idle go first, a download and a lease stay.
    @Test func theAppsFactsReachTheRules() {
        var download = HibernationPlanner.Candidate(key: "tab_dl", hiddenFor: 500 * 60)
        download.isDownloading = true
        var leased = HibernationPlanner.Candidate(key: "tab_agent", hiddenFor: 500 * 60)
        leased.hasAgentLease = true
        let candidates = (0..<5).map { HibernationPlanner.Candidate(key: "tab_\($0)", hiddenFor: (40 + Double($0)) * 60) } + [download, leased]
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .moderate), pressure: .normal, candidates: candidates)
        #expect(plan.due == ["tab_4", "tab_3"])
        #expect(plan.nextCheck == 5)
        #expect(plan.exemptions == ["tab_dl": .downloading, "tab_agent": .agentLease])
        #expect(HibernationPlanner.threshold(.unset, pressure: .normal) == 1_800)
        #expect(HibernationPlanner.threshold(BrowserHibernationSetting(mode: .off), pressure: .critical) == nil)
    }

    /// An agent's leased page does not freeze either: its next call would wait on a thaw.
    @Test func leasedPagesDoNotFreeze() {
        var leased = HibernationPlanner.Candidate(key: "agent", hiddenFor: 5 * 60)
        leased.hasAgentLease = true
        #expect(HibernationPlanner.freezePlan(.unset, candidates: [leased]).due.isEmpty)
    }

    /// "Never Hibernate This Site" adds the page's host once.
    @Test func neverHibernateSiteAddsTheHostOnce() {
        var setting = BrowserHibernationSetting.unset
        setting.exclusions = ["mail.google.com"]
        #expect(setting.addingExclusion(host: "Docs.Example.com").exclusions == ["mail.google.com", "docs.example.com"])
        #expect(setting.addingExclusion(host: "inbox.mail.google.com").exclusions == ["mail.google.com"])
        #expect(setting.addingExclusion(host: nil).exclusions == ["mail.google.com"])
    }
}
