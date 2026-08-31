import Foundation
import Testing
@testable import CmuxSidebar

@Suite("SidebarFilterIndex")
struct SidebarFilterIndexTests {
    // MARK: - Fixtures

    private static func workspace(
        _ id: UUID,
        title: String,
        branch: String? = nil,
        directory: String? = nil,
        pullRequest: String? = nil,
        ports: [String] = [],
        groupId: UUID? = nil,
        isGroupAnchor: Bool = false
    ) -> SidebarFilterCandidate {
        var fields: [SidebarFilterCandidateField] = [
            SidebarFilterCandidateField(field: .title, displayText: title)
        ]
        if let branch {
            fields.append(SidebarFilterCandidateField(field: .branch, displayText: branch))
        }
        if let directory {
            fields.append(SidebarFilterCandidateField(field: .directory, displayText: directory))
        }
        if let pullRequest {
            fields.append(SidebarFilterCandidateField(field: .pullRequest, displayText: pullRequest))
        }
        for port in ports {
            fields.append(SidebarFilterCandidateField(field: .port, displayText: port))
        }
        return SidebarFilterCandidate(
            id: id,
            groupId: groupId,
            isGroupAnchor: isGroupAnchor,
            fields: fields
        )
    }

    // MARK: - Passthrough

    @Test func emptyQueryReturnsInactiveOutcome() {
        let index = SidebarFilterIndex(
            candidates: [Self.workspace(UUID(), title: "cmux")],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("   "))
        #expect(outcome == .inactive)
        #expect(!outcome.isFiltering)
        #expect(!outcome.isEmptyResult)
    }

    @Test func inactiveOutcomeIncludesEveryWorkspace() {
        // Passthrough must not depend on the visible set being populated: an
        // inactive filter carries no ids at all and still shows every row.
        #expect(SidebarFilterOutcome.inactive.includesWorkspace(UUID()))
        #expect(!SidebarFilterOutcome.inactive.forcesGroupExpanded(UUID()))
    }

    // MARK: - Field matching

    @Test func matchesOnBranchWhenTitleSaysNothingAboutIt() {
        let id = UUID()
        let index = SidebarFilterIndex(
            candidates: [Self.workspace(id, title: "api", branch: "fix-drag-failsafe")],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("failsafe"))
        #expect(outcome.orderedMatchWorkspaceIds == [id])
        #expect(outcome.matchesByWorkspaceId[id]?.field == .branch)
    }

    @Test func matchesOnDirectory() {
        let id = UUID()
        let index = SidebarFilterIndex(
            candidates: [Self.workspace(id, title: "api", directory: "~/repos/manaflow")],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("manaflow"))
        #expect(outcome.matchesByWorkspaceId[id]?.field == .directory)
    }

    @Test func titleOutranksDirectoryForTheSameText() {
        let titled = UUID()
        let pathed = UUID()
        let index = SidebarFilterIndex(
            candidates: [
                Self.workspace(pathed, title: "unrelated", directory: "~/src/ghostty"),
                Self.workspace(titled, title: "ghostty"),
            ],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("ghostty"))
        #expect(outcome.bestMatchWorkspaceId == titled)
    }

    @Test func scopedQueryIgnoresOtherFields() {
        let branchHit = UUID()
        let titleHit = UUID()
        let index = SidebarFilterIndex(
            candidates: [
                Self.workspace(titleHit, title: "main"),
                Self.workspace(branchHit, title: "worker", branch: "main"),
            ],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("@main"))
        #expect(outcome.orderedMatchWorkspaceIds == [branchHit])
        #expect(outcome.matchesByWorkspaceId[titleHit] == nil)
    }

    @Test func portQueryFindsAListeningWorkspace() {
        let id = UUID()
        let index = SidebarFilterIndex(
            candidates: [Self.workspace(id, title: "web", ports: ["3000", "9229"])],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery(":9229"))
        #expect(outcome.orderedMatchWorkspaceIds == [id])
    }

    // MARK: - Ordering

    @Test func rowsKeepModelOrderRatherThanScoreOrder() {
        // A sidebar is spatial. Re-sorting by score on every keystroke would
        // move rows under the pointer mid-type, so the outcome preserves the
        // order the sidebar renders in and exposes ranking separately.
        let weak = UUID()
        let strong = UUID()
        let index = SidebarFilterIndex(
            candidates: [
                Self.workspace(weak, title: "unrelated", directory: "~/src/cmux"),
                Self.workspace(strong, title: "cmux"),
            ],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("cmux"))
        #expect(outcome.orderedMatchWorkspaceIds == [weak, strong])
        #expect(outcome.bestMatchWorkspaceId == strong)
    }

    // MARK: - Groups

    @Test func matchingMemberKeepsItsHeaderAndForcesTheGroupOpen() {
        let groupId = UUID()
        let anchor = UUID()
        let member = UUID()
        let index = SidebarFilterIndex(
            candidates: [
                Self.workspace(anchor, title: "infra", groupId: groupId, isGroupAnchor: true),
                Self.workspace(member, title: "deploy-runner", groupId: groupId),
            ],
            groups: [SidebarFilterGroup(id: groupId, anchorWorkspaceId: anchor, name: "infra")]
        )
        let outcome = index.outcome(for: SidebarFilterQuery("runner"))
        #expect(outcome.visibleWorkspaceIds == [anchor, member])
        #expect(outcome.expandedGroupIds == [groupId])
        // The header is context, not a hit.
        #expect(outcome.orderedMatchWorkspaceIds == [member])
    }

    @Test func matchingGroupNameKeepsEveryMemberAndOpensTheGroup() {
        let groupId = UUID()
        let anchor = UUID()
        let first = UUID()
        let second = UUID()
        let index = SidebarFilterIndex(
            candidates: [
                Self.workspace(anchor, title: "anchor", groupId: groupId, isGroupAnchor: true),
                Self.workspace(first, title: "alpha", groupId: groupId),
                Self.workspace(second, title: "beta", groupId: groupId),
            ],
            groups: [SidebarFilterGroup(id: groupId, anchorWorkspaceId: anchor, name: "infra")]
        )
        let outcome = index.outcome(for: SidebarFilterQuery("#infra"))
        #expect(outcome.visibleWorkspaceIds == [anchor, first, second])
        #expect(outcome.expandedGroupIds == [groupId])
    }

    @Test func anchorMatchingOnItsOwnTitleDoesNotForceTheGroupOpen() {
        // The anchor *is* the header. Typing its name is not a request to
        // expand the group the user deliberately collapsed.
        let groupId = UUID()
        let anchor = UUID()
        let member = UUID()
        let index = SidebarFilterIndex(
            candidates: [
                Self.workspace(anchor, title: "zephyr", groupId: groupId, isGroupAnchor: true),
                Self.workspace(member, title: "unrelated", groupId: groupId),
            ],
            groups: [SidebarFilterGroup(id: groupId, anchorWorkspaceId: anchor, name: "other")]
        )
        let outcome = index.outcome(for: SidebarFilterQuery("zephyr"))
        #expect(outcome.orderedMatchWorkspaceIds == [anchor])
        #expect(outcome.expandedGroupIds.isEmpty)
    }

    @Test func ungroupedWorkspacesNeverProduceGroupExpansion() {
        let id = UUID()
        let index = SidebarFilterIndex(
            candidates: [Self.workspace(id, title: "solo")],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("solo"))
        #expect(outcome.expandedGroupIds.isEmpty)
    }

    // MARK: - Empty results

    @Test func unmatchedQueryReportsAnEmptyResultRatherThanPassthrough() {
        let index = SidebarFilterIndex(
            candidates: [Self.workspace(UUID(), title: "cmux")],
            groups: []
        )
        let outcome = index.outcome(for: SidebarFilterQuery("zzzzqqq"))
        #expect(outcome.isFiltering)
        #expect(outcome.isEmptyResult)
        #expect(outcome.visibleWorkspaceIds.isEmpty)
        #expect(outcome.bestMatchWorkspaceId == nil)
    }
}
