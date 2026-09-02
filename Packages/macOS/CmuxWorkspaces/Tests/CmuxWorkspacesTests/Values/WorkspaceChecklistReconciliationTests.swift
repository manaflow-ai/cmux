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

        #expect(result.map(\.id) == [userItem.id, newID, otherSession.id, kept.id])
        #expect(result[3].text == "Updated task text")
        #expect(result[3].state == .completed)
        #expect(result[3].attachments == [attachment])
        #expect(result[3].ownerID == "claude:session-a")
        #expect(result[1].ownerID == "claude:session-a")
        #expect(result[2] == otherSession)
        #expect(result.dropLast().allSatisfy { $0.state != .completed })
        #expect(!result.contains(where: { $0.id == deleted.id }))
        #expect(checklist == result)
    }

    @Test func replaceChecklistPreservesExistingOwner() throws {
        let itemID = UUID()
        var checklist = [
            WorkspaceChecklistItem(
                id: itemID,
                text: "Old task",
                origin: .agent,
                ownerID: "claude:session-a"
            ),
        ]

        let result = try checklist.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(id: itemID, text: "Updated task"),
        ]).get()

        let replaced = try #require(result.first)
        #expect(replaced.ownerID == "claude:session-a")
        #expect(checklist == result)
    }

    @Test func replaceChecklistRejectsDuplicateExistingIDsAtomically() {
        let duplicateID = UUID()
        let original = [
            WorkspaceChecklistItem(
                id: duplicateID,
                text: "First persisted task",
                origin: .agent,
                ownerID: "claude:shared-list"
            ),
            WorkspaceChecklistItem(
                id: duplicateID,
                text: "Duplicate persisted task",
                origin: .agent,
                ownerID: "claude:shared-list"
            ),
        ]
        var checklist = original

        let result = checklist.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(id: duplicateID, text: "Updated task"),
        ])

        #expect(result == .failure(.duplicateId(index: 1)))
        #expect(checklist == original)
    }

    @Test func reconcileRejectsDuplicateUnrelatedExistingIDsAtomically() {
        let duplicateID = UUID()
        let original = [
            WorkspaceChecklistItem(id: duplicateID, text: "User task"),
            WorkspaceChecklistItem(
                id: duplicateID,
                text: "Other owner's task",
                origin: .agent,
                ownerID: "claude:session-b"
            ),
        ]
        var checklist = original

        let result = checklist.reconcileChecklist(ownerID: "claude:session-a", with: [
            WorkspaceChecklistReplacementItem(text: "New agent task", origin: .agent),
        ])

        #expect(result == .failure(.duplicateId(index: 1)))
        #expect(checklist == original)
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
