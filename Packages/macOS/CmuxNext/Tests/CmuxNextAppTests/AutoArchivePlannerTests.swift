import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Auto-archive (plans/cmux-next/auto-archive-DESIGN.md): the app's call into the planner's Rust
/// rules (whose cases are tested in `cmux-layout-reducer` `auto_archive_tests.rs`), the settings
/// parse and a group rule's wire value.
@Suite struct AutoArchivePlannerTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated static let day: TimeInterval = 86_400

    nonisolated static func ws(_ id: String, idleDays: Double?, groups: [String] = [], pinned: Bool = false, archived: Bool = false,
                   shown: Bool = false, running: Bool = false, attention: Bool = false) -> AutoArchivePlanner.Candidate {
        AutoArchivePlanner.Candidate(item: "itm_\(id)", workspace: id, title: id,
                                     lastActive: idleDays.map { now.addingTimeInterval(-$0 * day) }, groups: groups,
                                     pinned: pinned, archived: archived, shown: shown, running: running, needsAttention: attention)
    }

    /// The rules are Rust's (`cmux-layout-reducer` `auto_archive`, with their own tests); this proves
    /// the app's call: each field reaches Rust under its wire name and the reply maps back to the
    /// app's candidates (due idlest first, a group rule, the ledger's sight, a first sight, the snooze).
    @Test func thePlannerCallReachesRustAndMapsTheReplyBack() {
        let rules: [String: SidebarDocAutoArchiveRule] = ["g_ci": .afterHours(24), "g_keep": .never]
        let list = [
            Self.ws("fresh", idleDays: 1), Self.ws("ci", idleDays: 2, groups: ["g_ci"]), Self.ws("older", idleDays: 30),
            Self.ws("kept", idleDays: 90, groups: ["g_keep"]), Self.ws("pinned", idleDays: 40, pinned: true),
            Self.ws("shownHere", idleDays: 20), Self.ws("new", idleDays: nil),
        ]
        let seen = ["shownHere": Self.now.addingTimeInterval(-3600)]
        let policy = AutoArchivePolicy(style: .quiet, idleDays: 3)
        let plan = AutoArchivePlanner().plan(list, seen: seen, rules: rules, policy: policy, trigger: .background, now: Self.now)
        #expect(plan.due.map(\.workspace) == ["older", "ci"])
        #expect(plan.nextCheck == Self.now.addingTimeInterval(2 * Self.day))
        #expect(plan.firstSight == ["new"])
        #expect(!plan.snoozed)

        let suggest = AutoArchivePolicy(style: .suggest, idleDays: 3)
        let snoozed = AutoArchivePlanner().plan(list, rules: rules, policy: suggest, trigger: .background, now: Self.now,
                                                snoozedUntil: Self.now.addingTimeInterval(3 * Self.day))
        #expect(snoozed.due.isEmpty && snoozed.snoozed)
        #expect(snoozed.nextCheck == Self.now.addingTimeInterval(3 * Self.day))
        // The sweep runs under Off and still honors a group's Never; without the ledger's sight, shownHere is idle.
        let sweep = AutoArchivePlanner().plan(list, rules: rules, policy: AutoArchivePolicy(style: .off), trigger: .sweep, now: Self.now)
        #expect(sweep.due.map(\.workspace) == ["older", "shownHere", "ci"])
    }

    @Test func settingsParseTheStyleAndDaysAndFallBackOnBadValues() throws {
        func parse(_ json: String) throws -> (AutoArchiveSettings, Int) {
            let root = try JSONValue.parse(Data(json.utf8))
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            return (snapshot.autoArchive, snapshot.diagnostics.filter { $0.path.hasPrefix("workspaces.autoArchive") }.count)
        }
        let defaults = try parse("{}")
        #expect(defaults.0 == AutoArchiveSettings(style: .manual, idleDays: 3) && defaults.1 == 0)
        let set = try parse(#"{"workspaces":{"autoArchive":{"style":"quiet","idleDays":14}}}"#)
        #expect(set.0 == AutoArchiveSettings(style: .quiet, idleDays: 14) && set.1 == 0)
        let bad = try parse(#"{"workspaces":{"autoArchive":{"style":"soon","idleDays":9000}}}"#)
        #expect(bad.0 == AutoArchiveSettings(style: .manual, idleDays: 365) && bad.1 == 2)
    }

    @Test func aGroupRuleReadsOnlyNeverOrWholeHoursInRange() {
        #expect(SidebarDocAutoArchiveRule(wire: "never") == .never)
        #expect(SidebarDocAutoArchiveRule(wire: NSNumber(value: 72)) == .afterHours(72))
        #expect(SidebarDocAutoArchiveRule(wire: NSNumber(value: 0)) == nil)
        #expect(SidebarDocAutoArchiveRule(wire: NSNumber(value: 1.5)) == nil)
        #expect(SidebarDocAutoArchiveRule(wire: NSNumber(value: true)) == nil)
        #expect(SidebarDocAutoArchiveRule(wire: "soon") == nil)
    }
}
