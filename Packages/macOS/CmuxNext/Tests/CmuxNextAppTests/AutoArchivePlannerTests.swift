import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Auto-archive (plans/cmux-next/auto-archive-DESIGN.md): which idle workspaces the planner offers
/// under each style, what always keeps a workspace, how a group's rule wins over the days, and
/// when the next pass is due.
@Suite struct AutoArchivePlannerTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated static let day: TimeInterval = 86_400

    nonisolated static func ws(_ id: String, idleDays: Double?, groups: [String] = [], pinned: Bool = false, archived: Bool = false,
                   shown: Bool = false, running: Bool = false, attention: Bool = false) -> AutoArchivePlanner.Candidate {
        AutoArchivePlanner.Candidate(item: "itm_\(id)", workspace: id, title: id,
                                     lastActive: idleDays.map { now.addingTimeInterval(-$0 * day) }, groups: groups,
                                     pinned: pinned, archived: archived, shown: shown, running: running, needsAttention: attention)
    }

    nonisolated static func due(_ candidates: [AutoArchivePlanner.Candidate], style: AutoArchivePolicy.Style, days: Double = 3,
                    rules: [String: SidebarDocAutoArchiveRule] = [:], trigger: AutoArchivePlanner.Trigger = .background) -> [String] {
        AutoArchivePlanner().plan(candidates, rules: rules, policy: AutoArchivePolicy(style: style, idleDays: days),
                                  trigger: trigger, now: now).due.map(\.workspace)
    }

    @Test func suggestAndQuietOfferWorkspacesIdlePastTheDaysIdlestFirst() {
        let list = [Self.ws("fresh", idleDays: 1), Self.ws("old", idleDays: 4), Self.ws("older", idleDays: 30)]
        #expect(Self.due(list, style: .suggest) == ["older", "old"])
        #expect(Self.due(list, style: .quiet) == ["older", "old"])
        #expect(Self.due(list, style: .quiet, days: 10) == ["older"])
    }

    @Test func offAndManualNeverRunInTheBackgroundButTheSweepDoes() {
        let list = [Self.ws("old", idleDays: 9)]
        #expect(Self.due(list, style: .off).isEmpty)
        #expect(Self.due(list, style: .manual).isEmpty)
        #expect(Self.due(list, style: .manual, trigger: .sweep) == ["old"])
        #expect(Self.due(list, style: .off, trigger: .sweep) == ["old"])
    }

    @Test(arguments: [
        ("pinned", ws("w", idleDays: 40, pinned: true)),
        ("archived", ws("w", idleDays: 40, archived: true)),
        ("shown", ws("w", idleDays: 40, shown: true)),
        ("running", ws("w", idleDays: 40, running: true)),
        ("attention", ws("w", idleDays: 40, attention: true)),
        ("never seen", ws("w", idleDays: nil)),
    ])
    func somethingAlwaysKeepsAWorkspace(_ reason: String, _ candidate: AutoArchivePlanner.Candidate) {
        #expect(Self.due([candidate], style: .quiet).isEmpty, "\(reason) must keep it")
        #expect(Self.due([candidate], style: .quiet, trigger: .sweep).isEmpty, "\(reason) must keep it from a sweep")
    }

    @Test func theNearestGroupWithARuleWins() {
        let rules: [String: SidebarDocAutoArchiveRule] = ["g_outer": .afterHours(24), "g_keep": .never]
        let list = [
            Self.ws("inOuter", idleDays: 2, groups: ["g_inner", "g_outer"]),
            Self.ws("kept", idleDays: 90, groups: ["g_keep", "g_outer"]),
            Self.ws("loose", idleDays: 2),
        ]
        #expect(Self.due(list, style: .quiet, rules: rules) == ["inOuter"])
        // The person's sweep still honors Never.
        #expect(Self.due(list, style: .manual, rules: rules, trigger: .sweep) == ["inOuter"])
    }

    @Test func theGroupsStyleArchivesOnlyWhereAGroupSetARule() {
        let rules: [String: SidebarDocAutoArchiveRule] = ["g_ci": .afterHours(12)]
        let list = [Self.ws("ci", idleDays: 1, groups: ["g_ci"]), Self.ws("loose", idleDays: 50), Self.ws("other", idleDays: 50, groups: ["g_x"])]
        #expect(Self.due(list, style: .groups, rules: rules) == ["ci"])
        #expect(Self.due(list, style: .groups, rules: rules, trigger: .sweep) == ["loose", "other", "ci"])
    }

    @Test func offIgnoresGroupRulesInTheBackground() {
        let rules: [String: SidebarDocAutoArchiveRule] = ["g_ci": .afterHours(1)]
        #expect(Self.due([Self.ws("ci", idleDays: 1, groups: ["g_ci"])], style: .off, rules: rules).isEmpty)
    }

    @Test func theNextCheckIsTheSoonestDeadlineAndNeverSoonerThanAMinute() {
        let planner = AutoArchivePlanner()
        let policy = AutoArchivePolicy(style: .quiet, idleDays: 3)
        let list = [Self.ws("a", idleDays: 1), Self.ws("b", idleDays: 2.5), Self.ws("pinned", idleDays: 2.9, pinned: true)]
        let plan = planner.plan(list, rules: [:], policy: policy, trigger: .background, now: Self.now)
        #expect(plan.due.isEmpty)
        #expect(plan.nextCheck == Self.now.addingTimeInterval(0.5 * Self.day))
        let almost = [Self.ws("c", idleDays: 3 - 1 / Self.day)]
        let soon = planner.plan(almost, rules: [:], policy: policy, trigger: .background, now: Self.now)
        #expect(soon.nextCheck == Self.now.addingTimeInterval(AutoArchivePlanner.minimumRecheck))
        #expect(planner.plan([], rules: [:], policy: policy, trigger: .background, now: Self.now).nextCheck == nil)
    }

    @Test func settingsParseTheStyleAndDaysAndFallBackOnBadValues() throws {
        func parse(_ json: String) throws -> (AutoArchiveSettings, Int) {
            let root = try JSONValue.parse(Data(json.utf8))
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            return (snapshot.autoArchive, snapshot.diagnostics.filter { $0.path.hasPrefix("workspaces.autoArchive") }.count)
        }
        let defaults = try parse("{}")
        #expect(defaults.0 == AutoArchiveSettings(style: .suggest, idleDays: 3) && defaults.1 == 0)
        let set = try parse(#"{"workspaces":{"autoArchive":{"style":"quiet","idleDays":14}}}"#)
        #expect(set.0 == AutoArchiveSettings(style: .quiet, idleDays: 14) && set.1 == 0)
        let bad = try parse(#"{"workspaces":{"autoArchive":{"style":"soon","idleDays":9000}}}"#)
        #expect(bad.0 == AutoArchiveSettings(style: .suggest, idleDays: 365) && bad.1 == 2)
    }

    @Test func aGroupRuleReadsOnlyNeverOrWholeHoursInRange() {
        #expect(SidebarDocAutoArchiveRule(wire: "never") == .never)
        #expect(SidebarDocAutoArchiveRule(wire: NSNumber(value: 72)) == .afterHours(72))
        #expect(SidebarDocAutoArchiveRule(wire: NSNumber(value: 0)) == nil)
        #expect(SidebarDocAutoArchiveRule(wire: NSNumber(value: 1.5)) == nil)
        #expect(SidebarDocAutoArchiveRule(wire: NSNumber(value: true)) == nil)
        #expect(SidebarDocAutoArchiveRule(wire: "soon") == nil)
        #expect(SidebarDocAutoArchiveRule.afterHours(24).idleSeconds == 86_400)
    }
}
