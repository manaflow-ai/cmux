import AppKit
@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Red CI in the Priority view and the rows' chip: a chat whose pull request's checks fail reads
/// "CI failing" whenever the Priority view or the session tree is on (the tree's pull request
/// reads serve both, no new GitHub poll), never with both off, and its row offers no Mark as
/// Read, which would change nothing.
@MainActor @Suite(.serialized) struct SidebarPriorityRedCITests {
    static let folder = "/Users/me/cmux"

    static func lane(_ id: String, _ state: AgentActivityLane.State, cwd: String? = folder) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: nil, parent: nil, state: state, since: Date(), error: nil,
                          project: "cmux", cwd: cwd)
    }

    static func pullRequest(checks: String, state: String = "open") -> AgentPanePullRequest {
        AgentPanePullRequest(url: "https://github.com/o/r/pull/7", number: 7, title: "Fix", state: state,
                             checks: .init(state: checks, passed: 0, total: 1))
    }

    static func sections(tree: Bool, priority: Bool) -> SidebarSectionsPreferences {
        var sections = SidebarSectionsPreferences.defaults
        sections.sessionTree = tree
        sections.priorityViewEnabled = priority
        return sections
    }

    @Test func failingChecksReadWhileThePriorityViewOrTheTreeIsOn() {
        let failing = [Self.folder: Self.pullRequest(checks: "failing")]
        let lane = Self.lane("red", .idle)
        #expect(SidebarSessionTreeFeed.checksFailing(lane, answers: failing, sections: Self.sections(tree: false, priority: true)))
        #expect(SidebarSessionTreeFeed.checksFailing(lane, answers: failing, sections: Self.sections(tree: true, priority: false)))
        #expect(!SidebarSessionTreeFeed.checksFailing(lane, answers: failing, sections: Self.sections(tree: false, priority: false)))
        #expect(SidebarSessionTreeFeed.readsPullRequests(Self.sections(tree: false, priority: true)))
        #expect(!SidebarSessionTreeFeed.readsPullRequests(Self.sections(tree: false, priority: false)))
        // Passing checks, a draft, another folder: no Red CI.
        let on = Self.sections(tree: false, priority: true)
        #expect(!SidebarSessionTreeFeed.checksFailing(lane, answers: [Self.folder: Self.pullRequest(checks: "passing")], sections: on))
        #expect(!SidebarSessionTreeFeed.checksFailing(lane, answers: [Self.folder: Self.pullRequest(checks: "failing", state: "draft")],
                                                      sections: on))
        #expect(!SidebarSessionTreeFeed.checksFailing(Self.lane("elsewhere", .idle, cwd: "/tmp/other"), answers: failing, sections: on))
    }

    @Test func theRowChipSaysCIFailing() {
        let lanes = [Self.lane("red", .idle), Self.lane("busy", .working)]
        #expect(SidebarLaneStatus.chip(lanes, marks: .init(), failingChecks: { $0.id == "red" }) == .ciFailing)
        #expect(SidebarLaneStatus.chip(lanes, marks: .init(), failingChecks: { _ in false }) == nil)
        // A question still outranks red checks.
        #expect(SidebarLaneStatus.chip(lanes + [Self.lane("asks", .input)], marks: .init(), failingChecks: { _ in true }) == .needsYou)
    }

    @Test func aRedCIRowOffersNoMarkAsRead() throws {
        func markRead(_ state: SidebarPriorityEntry.State) throws -> Bool {
            let row = SidebarPriorityRowView(entry: SidebarPriorityEntry(id: "chat", title: "Chat", state: state))
            let button = try #require(row.subviews.compactMap { $0 as? SidebarIconButton }.first { $0.label == CmuxNextSidebar.Strings.priorityMarkRead })
            return button.isEnabled
        }
        #expect(try !markRead(.ciFailing))
        #expect(try markRead(.done))
        #expect(try markRead(.failed))
    }
}
