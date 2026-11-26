import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite struct WorkspaceChecklistReplacementTests {
    @Test func replaceKeepsIdentityAndOriginForMatchedIds() throws {
        let attachment = WorkspaceChecklistAttachment(
            displayName: "screenshot.png",
            filePath: "/tmp/screenshot.png",
            byteCount: 100,
            contentTypeIdentifier: "public.png",
            pixelWidth: 20,
            pixelHeight: 10
        )
        let keep = WorkspaceChecklistItem(
            text: "keep me",
            state: .inProgress,
            origin: .agent,
            attachments: [attachment]
        )
        let drop = WorkspaceChecklistItem(text: "drop me")
        var items = [keep, drop]

        let result = try items.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(id: keep.id, text: "keep me (edited)"),
            WorkspaceChecklistReplacementItem(text: "brand new"),
        ]).get()

        #expect(result.count == 2)
        #expect(result[0].id == keep.id)
        #expect(result[0].text == "keep me (edited)")
        // Matched items keep their existing origin and (absent an incoming
        // state) their existing state.
        #expect(result[0].origin == .agent)
        #expect(result[0].state == .inProgress)
        #expect(result[0].attachments == [attachment])
        // Unmatched existing items are removed.
        #expect(!result.contains(where: { $0.id == drop.id }))
        #expect(result[1].text == "brand new")
        #expect(result[1].origin == .user)
        #expect(result[1].state == .pending)
        #expect(result[1].attachments.isEmpty)
        #expect(items == result)
    }

    @Test func replaceAppliesIncomingStateToMatchedItems() throws {
        let attachment = WorkspaceChecklistAttachment(displayName: "image.png", filePath: "/tmp/image.png")
        let existing = WorkspaceChecklistItem(
            text: "task",
            state: .pending,
            origin: .user,
            attachments: [attachment]
        )
        var items = [existing]
        let result = try items.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(id: existing.id, text: "task", state: .completed),
        ]).get()
        #expect(result[0].id == existing.id)
        #expect(result[0].state == .completed)
        #expect(result[0].attachments == [attachment])
    }

    @Test func replaceCreatesNewItemsWithGivenIdOriginAndState() throws {
        var items: [WorkspaceChecklistItem] = []
        let mintedId = UUID()
        let result = try items.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(
                id: mintedId,
                text: "agent task",
                state: .inProgress,
                origin: .agent
            ),
        ]).get()
        #expect(result[0].id == mintedId)
        #expect(result[0].state == .inProgress)
        #expect(result[0].origin == .agent)
    }

    @Test func replacePreservesIncomingOrder() throws {
        let a = WorkspaceChecklistItem(text: "a")
        let b = WorkspaceChecklistItem(text: "b")
        var items = [a, b]
        let result = try items.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(id: b.id, text: "b"),
            WorkspaceChecklistReplacementItem(id: a.id, text: "a"),
        ]).get()
        #expect(result.map(\.id) == [b.id, a.id])
    }

    @Test func replaceNormalizesTextLikeAdd() throws {
        var items: [WorkspaceChecklistItem] = []
        let long = String(repeating: "y", count: WorkspaceChecklistItem.maxTextLength + 50)
        let result = try items.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(text: "  padded  \n"),
            WorkspaceChecklistReplacementItem(text: long),
        ]).get()
        #expect(result[0].text == "padded")
        #expect(result[1].text.count == WorkspaceChecklistItem.maxTextLength)
    }

    @Test func replaceRejectsEmptyTextAtomically() {
        let existing = WorkspaceChecklistItem(text: "untouched")
        var items = [existing]
        let result = items.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(text: "fine"),
            WorkspaceChecklistReplacementItem(text: "   "),
        ])
        #expect(result == .failure(.emptyText(index: 1)))
        // Atomic: nothing mutated on rejection.
        #expect(items == [existing])
    }

    @Test func replaceRejectsDuplicateMatchedIdAtomically() {
        let existing = WorkspaceChecklistItem(text: "untouched")
        var items = [existing]
        let result = items.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(id: existing.id, text: "first"),
            WorkspaceChecklistReplacementItem(id: existing.id, text: "second"),
        ])
        #expect(result == .failure(.duplicateId(index: 1)))
        #expect(items == [existing])
    }

    @Test func replaceRejectsDuplicateNewIdAtomically() {
        let existing = WorkspaceChecklistItem(text: "untouched")
        let newId = UUID()
        var items = [existing]
        let result = items.replaceChecklist(with: [
            WorkspaceChecklistReplacementItem(id: newId, text: "first"),
            WorkspaceChecklistReplacementItem(id: UUID(), text: "middle"),
            WorkspaceChecklistReplacementItem(id: newId, text: "second"),
        ])
        #expect(result == .failure(.duplicateId(index: 2)))
        #expect(items == [existing])
    }

    @Test func replaceRejectsOverCapAtomically() {
        let existing = WorkspaceChecklistItem(text: "untouched")
        var items = [existing]
        let overCap = (0...WorkspaceChecklistItem.maxChecklistItems).map {
            WorkspaceChecklistReplacementItem(text: "item \($0)")
        }
        let result = items.replaceChecklist(with: overCap)
        #expect(result == .failure(.tooManyItems(count: overCap.count)))
        #expect(items == [existing])
    }

    @Test func replaceWithEmptyListClears() throws {
        var items = [WorkspaceChecklistItem(text: "a"), WorkspaceChecklistItem(text: "b")]
        let result = try items.replaceChecklist(with: []).get()
        #expect(result.isEmpty)
        #expect(items.isEmpty)
    }
}
