import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite struct WorkspaceChecklistReconciliationTests {
    @Test func reconcileReplacesOnlyTheMatchingOwner() throws {
        let attachment = WorkspaceChecklistAttachment(
            displayName: "proof.png",
            filePath: "/tmp/proof.png"
        )
        let userItem = WorkspaceChecklistItem(text: "User note")
        let kept = WorkspaceChecklistItem(
            id: UUID(),
            text: "Old task text",
            state: .pending,
            origin: .agent,
            ownerID: "claude:session-a",
            attachments: [attachment]
        )
        let deleted = WorkspaceChecklistItem(
            text: "Deleted task",
            origin: .agent,
            ownerID: "claude:session-a"
        )
        let otherSession = WorkspaceChecklistItem(
            text: "Other session task",
            origin: .agent,
            ownerID: "claude:session-b"
        )
        let newID = UUID()
        var checklist = [userItem, kept, deleted, otherSession]

        let result = try checklist.reconcileChecklist(ownerID: "claude:session-a", with: [
            WorkspaceChecklistReplacementItem(
                id: kept.id,
                text: "Updated task text",
                state: .completed,
                origin: .agent
            ),
            WorkspaceChecklistReplacementItem(
                id: newID,
                text: "New task",
                state: .inProgress,
                origin: .agent
            ),
        ]).get()

        #expect(result.map(\.id) == [userItem.id, kept.id, newID, otherSession.id])
        #expect(result[1].text == "Updated task text")
        #expect(result[1].state == .completed)
        #expect(result[1].attachments == [attachment])
        #expect(result[1].ownerID == "claude:session-a")
        #expect(result[2].ownerID == "claude:session-a")
        #expect(result[3] == otherSession)
        #expect(!result.contains(where: { $0.id == deleted.id }))
        #expect(checklist == result)
    }

    @Test func emptySnapshotRemovesOnlyMatchingOwner() throws {
        let userItem = WorkspaceChecklistItem(text: "User note")
        let owned = WorkspaceChecklistItem(
            text: "Deleted task",
            origin: .agent,
            ownerID: "claude:session-a"
        )
        var checklist = [userItem, owned]

        let result = try checklist.reconcileChecklist(
            ownerID: "claude:session-a",
            with: []
        ).get()

        #expect(result == [userItem])
    }

    @Test func reconcileRejectsUnrelatedIDCollisionAtomically() {
        let userItem = WorkspaceChecklistItem(text: "User note")
        var checklist = [userItem]

        let result = checklist.reconcileChecklist(ownerID: "claude:session-a", with: [
            WorkspaceChecklistReplacementItem(
                id: userItem.id,
                text: "Agent task",
                origin: .agent
            ),
        ])

        #expect(result == .failure(.duplicateId(index: 0)))
        #expect(checklist == [userItem])
    }

    @Test func reconcileRejectsCombinedChecklistOverCapAtomically() {
        let original = (0..<(WorkspaceChecklistItem.maxChecklistItems - 1)).map {
            WorkspaceChecklistItem(text: "User item \($0)")
        }
        var checklist = original

        let result = checklist.reconcileChecklist(ownerID: "claude:session-a", with: [
            WorkspaceChecklistReplacementItem(text: "Agent task 1", origin: .agent),
            WorkspaceChecklistReplacementItem(text: "Agent task 2", origin: .agent),
        ])

        #expect(result == .failure(.tooManyItems(count: WorkspaceChecklistItem.maxChecklistItems + 1)))
        #expect(checklist == original)
    }

    @Test func checklistCodableRoundTripPreservesOwner() throws {
        let original = WorkspaceChecklistItem(
            text: "Agent task",
            origin: .agent,
            ownerID: "claude:session-a"
        )

        let decoded = try JSONDecoder().decode(
            WorkspaceChecklistItem.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded == original)
    }
}
