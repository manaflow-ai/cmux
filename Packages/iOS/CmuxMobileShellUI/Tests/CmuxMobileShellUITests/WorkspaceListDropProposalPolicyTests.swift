#if os(iOS)
import CmuxMobileShellModel
import Testing

@testable import CmuxMobileShellUI

@Suite struct WorkspaceListDropProposalPolicyTests {
    private let groupHeader = WorkspaceListTableItem.groupHeader(
        .init(rawValue: "target-group")
    )
    private let draggedWorkspace = WorkspaceListTableItem.workspace(
        .init(rawValue: "dragged-workspace"),
        indented: false
    )

    @Test func middleBandDropsIntoEligibleGroupHeader() {
        let decision = WorkspaceListDropProposalPolicy().decision(
            hitItem: groupHeader,
            draggedItem: draggedWorkspace,
            yOffset: 22,
            rowHeight: 44,
            canDropIntoGroup: true
        )

        #expect(decision == .into)
    }

    @Test func topAndBottomEdgeBandsRemainInsertionGaps() {
        let policy = WorkspaceListDropProposalPolicy()

        #expect(policy.decision(
            hitItem: groupHeader,
            draggedItem: draggedWorkspace,
            yOffset: 4,
            rowHeight: 44,
            canDropIntoGroup: true
        ) == .insertAt)
        #expect(policy.decision(
            hitItem: groupHeader,
            draggedItem: draggedWorkspace,
            yOffset: 40,
            rowHeight: 44,
            canDropIntoGroup: true
        ) == .insertAt)
    }

    @Test func draggedGroupHeaderNeverDropsIntoAnotherHeader() {
        let decision = WorkspaceListDropProposalPolicy().decision(
            hitItem: groupHeader,
            draggedItem: .groupHeader(.init(rawValue: "dragged-group")),
            yOffset: 22,
            rowHeight: 44,
            canDropIntoGroup: true
        )

        #expect(decision == .insertAt)
    }

    @Test func ineligibleWorkspaceFallsBackToInsertion() {
        let decision = WorkspaceListDropProposalPolicy().decision(
            hitItem: groupHeader,
            draggedItem: draggedWorkspace,
            yOffset: 22,
            rowHeight: 44,
            canDropIntoGroup: false
        )

        #expect(decision == .insertAt)
    }

    @Test func nonHeaderTargetFallsBackToInsertion() {
        let decision = WorkspaceListDropProposalPolicy().decision(
            hitItem: .workspace(.init(rawValue: "target-workspace"), indented: false),
            draggedItem: draggedWorkspace,
            yOffset: 22,
            rowHeight: 44,
            canDropIntoGroup: true
        )

        #expect(decision == .insertAt)
    }

    @Test func chromeTargetIsForbidden() {
        let decision = WorkspaceListDropProposalPolicy().decision(
            hitItem: .chrome(.macStatusRow),
            draggedItem: draggedWorkspace,
            yOffset: 22,
            rowHeight: 44,
            canDropIntoGroup: false
        )

        #expect(decision == .forbidden)
    }
}
#endif
