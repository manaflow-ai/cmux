import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite struct WorkspaceChecklistTests {
    private func sampleAttachment(
        id: UUID = UUID(),
        filePath: String = "/tmp/cmux-checklist-image.png"
    ) -> WorkspaceChecklistAttachment {
        WorkspaceChecklistAttachment(
            id: id,
            displayName: " screenshot.png ",
            filePath: filePath,
            byteCount: 2048,
            contentTypeIdentifier: " public.png ",
            pixelWidth: 640,
            pixelHeight: 480
        )
    }

    /// Raw values are a control-socket and session wire format; frozen.
    @Test func stateAndOriginRawValuesAreFrozenWireValues() {
        #expect(WorkspaceChecklistItem.State.pending.rawValue == "pending")
        #expect(WorkspaceChecklistItem.State.inProgress.rawValue == "in-progress")
        #expect(WorkspaceChecklistItem.State.completed.rawValue == "completed")
        #expect(WorkspaceChecklistItem.Origin.user.rawValue == "user")
        #expect(WorkspaceChecklistItem.Origin.agent.rawValue == "agent")
    }

    @Test func addTrimsTextAndAppends() throws {
        var items: [WorkspaceChecklistItem] = []
        let added = try items.addChecklistItem("  fix the bug  \n", origin: .agent).get()
        #expect(added.text == "fix the bug")
        #expect(added.state == .pending)
        #expect(added.origin == .agent)
        #expect(added.attachments.isEmpty)
        #expect(items == [added])
    }

    @Test func addRejectsEmptyAndWhitespaceOnlyText() {
        var items: [WorkspaceChecklistItem] = []
        #expect(items.addChecklistItem("") == .failure(.emptyText))
        #expect(items.addChecklistItem("   \n\t") == .failure(.emptyText))
        #expect(items.isEmpty)
    }

    @Test func addCapsTextLength() throws {
        var items: [WorkspaceChecklistItem] = []
        let long = String(repeating: "x", count: WorkspaceChecklistItem.maxTextLength + 100)
        let added = try items.addChecklistItem(long).get()
        #expect(added.text.count == WorkspaceChecklistItem.maxTextLength)
    }

    @Test func addRejectsWhenFull() {
        var items = (0..<WorkspaceChecklistItem.maxChecklistItems).map {
            WorkspaceChecklistItem(text: "item \($0)")
        }
        #expect(items.addChecklistItem("one too many") == .failure(.checklistFull))
        #expect(items.count == WorkspaceChecklistItem.maxChecklistItems)
    }

    @Test func setTextByIdNormalizesAndRejectsEmpty() {
        let attachment = sampleAttachment()
        var items = [
            WorkspaceChecklistItem(text: "a"),
            WorkspaceChecklistItem(text: "b", attachments: [attachment]),
        ]
        let edited = items.setChecklistItemText(id: items[1].id, text: "  b revised  \n")
        #expect(edited)
        #expect(items[1].text == "b revised")
        #expect(items[1].attachments == [attachment])
        #expect(items[0].text == "a")
        let emptyEdit = items.setChecklistItemText(id: items[1].id, text: "   ")
        #expect(!emptyEdit)
        #expect(items[1].text == "b revised")
        #expect(items[1].attachments == [attachment])
        let unknownEdit = items.setChecklistItemText(id: UUID(), text: "x")
        #expect(!unknownEdit)
    }

    @Test func setStateByIdUpdatesOnlyThatItem() {
        let attachment = sampleAttachment()
        var items = [
            WorkspaceChecklistItem(text: "a"),
            WorkspaceChecklistItem(text: "b", attachments: [attachment]),
        ]
        let updatedKnown = items.setChecklistItemState(id: items[1].id, state: .inProgress)
        #expect(updatedKnown)
        #expect(items[0].state == .pending)
        #expect(items[1].state == .inProgress)
        #expect(items[1].attachments == [attachment])
        let updatedUnknown = items.setChecklistItemState(id: UUID(), state: .completed)
        #expect(!updatedUnknown)
    }

    @Test func removeByIdAndClear() {
        let attachment = sampleAttachment()
        var items = [
            WorkspaceChecklistItem(text: "a", attachments: [attachment]),
            WorkspaceChecklistItem(text: "b"),
        ]
        let removedKnown = items.removeChecklistItem(id: items[0].id)
        #expect(removedKnown)
        #expect(items.map(\.text) == ["b"])
        #expect(items.flatMap(\.attachments).isEmpty)
        let removedUnknown = items.removeChecklistItem(id: UUID())
        #expect(!removedUnknown)
        let clearedCount = items.clearChecklist()
        #expect(clearedCount == 1)
        #expect(items.isEmpty)
        let clearedAgain = items.clearChecklist()
        #expect(clearedAgain == 0)
    }

    @Test func progressSummaryCountsAndFirstUnchecked() {
        var items = [
            WorkspaceChecklistItem(text: "done one", state: .completed),
            WorkspaceChecklistItem(text: "doing", state: .inProgress),
            WorkspaceChecklistItem(text: "later", state: .pending),
        ]
        let summary = items.checklistProgressSummary
        #expect(summary.completedCount == 1)
        #expect(summary.totalCount == 3)
        #expect(summary.firstUncheckedText == "doing")

        for item in items {
            items.setChecklistItemState(id: item.id, state: .completed)
        }
        let allDone = items.checklistProgressSummary
        #expect(allDone.completedCount == 3)
        #expect(allDone.firstUncheckedText == nil)

        let empty = [WorkspaceChecklistItem]().checklistProgressSummary
        #expect(empty.completedCount == 0)
        #expect(empty.totalCount == 0)
        #expect(empty.firstUncheckedText == nil)
    }

    @Test func itemCodableRoundTrip() throws {
        let attachment = sampleAttachment()
        let item = WorkspaceChecklistItem(
            text: "ship it",
            state: .inProgress,
            origin: .agent,
            attachments: [attachment]
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WorkspaceChecklistItem.self, from: data)
        #expect(decoded == item)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("in-progress"))
        #expect(json.contains("attachments"))
    }

    @Test func itemDecodesLegacyJSONWithoutAttachments() throws {
        let itemID = UUID()
        let json = """
        {
          "id": "\(itemID.uuidString)",
          "text": "legacy item",
          "state": "pending",
          "origin": "user"
        }
        """
        let decoded = try JSONDecoder().decode(WorkspaceChecklistItem.self, from: Data(json.utf8))
        #expect(decoded == WorkspaceChecklistItem(id: itemID, text: "legacy item"))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
        let object = try #require(encoded as? [String: Any])
        #expect(object["attachments"] == nil)
    }

    @Test func itemDecodesLossyAttachments() throws {
        let itemID = UUID()
        let attachmentID = UUID()
        let json = """
        {
          "id": "\(itemID.uuidString)",
          "text": "with attachments",
          "state": "pending",
          "origin": "user",
          "attachments": [
            {
              "id": "\(attachmentID.uuidString)",
              "displayName": " image.png ",
              "filePath": "/tmp/image.png",
              "byteCount": 128,
              "contentTypeIdentifier": " public.png ",
              "pixelWidth": 320,
              "pixelHeight": 240
            },
            { "displayName": "missing path" },
            42,
            {
              "displayName": "",
              "filePath": "/tmp/fallback.jpg",
              "byteCount": -1,
              "contentTypeIdentifier": " ",
              "pixelWidth": 0,
              "pixelHeight": -4
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(WorkspaceChecklistItem.self, from: Data(json.utf8))
        #expect(decoded.id == itemID)
        #expect(decoded.attachments.count == 2)
        #expect(decoded.attachments[0] == WorkspaceChecklistAttachment(
            id: attachmentID,
            displayName: "image.png",
            filePath: "/tmp/image.png",
            byteCount: 128,
            contentTypeIdentifier: "public.png",
            pixelWidth: 320,
            pixelHeight: 240
        ))
        #expect(decoded.attachments[1].displayName == "fallback.jpg")
        #expect(decoded.attachments[1].filePath == "/tmp/fallback.jpg")
        #expect(decoded.attachments[1].byteCount == nil)
        #expect(decoded.attachments[1].contentTypeIdentifier == nil)
        #expect(decoded.attachments[1].pixelWidth == nil)
        #expect(decoded.attachments[1].pixelHeight == nil)
    }

    @Test func attachmentMetadataSupportsCountsAndMissingFileChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingURL = directory.appendingPathComponent("existing.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: existingURL)
        let missingURL = directory.appendingPathComponent("missing.png")
        let item = WorkspaceChecklistItem(
            text: "inspect images",
            attachments: [
                WorkspaceChecklistAttachment(displayName: "", fileURL: existingURL),
                WorkspaceChecklistAttachment(displayName: "", fileURL: missingURL),
            ]
        )
        #expect(item.attachmentCount == 2)
        #expect(!item.attachments[0].isMissing())
        #expect(item.attachments[1].isMissing())
        #expect(item.hasMissingAttachments())
    }

    @Test func completingAnItemMovesItAfterUncompletedInStorage() {
        let attachment = sampleAttachment()
        var items = [
            WorkspaceChecklistItem(text: "a", attachments: [attachment]),
            WorkspaceChecklistItem(text: "b"),
            WorkspaceChecklistItem(text: "c"),
        ]
        // Complete the first item; storage must re-partition so it sits last.
        _ = items.setChecklistItemState(id: items[0].id, state: .completed)
        #expect(items.map(\.text) == ["b", "c", "a"])
        #expect(items.last?.state == .completed)
        #expect(items.last?.attachments == [attachment])
        // Un-completing moves it back to the end of the uncompleted run.
        _ = items.setChecklistItemState(id: items[2].id, state: .pending)
        #expect(items.allSatisfy { $0.state != .completed })
        #expect(items.map(\.text) == ["b", "c", "a"])
        #expect(items.last?.attachments == [attachment])
    }

    @Test func moveReordersWithinCompletionGroupOnly() {
        let attachment = sampleAttachment()
        var items = [
            WorkspaceChecklistItem(text: "u1"),
            WorkspaceChecklistItem(text: "u2"),
            WorkspaceChecklistItem(text: "u3", attachments: [attachment]),
            WorkspaceChecklistItem(text: "d1", state: .completed),
            WorkspaceChecklistItem(text: "d2", state: .completed),
        ]
        // Move u3 to the front: reorders within the uncompleted run.
        _ = items.moveChecklistItem(id: items[2].id, toIndex: 0)
        #expect(items.map(\.text) == ["u3", "u1", "u2", "d1", "d2"])
        #expect(items[0].attachments == [attachment])
        // Try to move a completed item into the uncompleted region: it clamps
        // to the start of the completed run, never before uncompleted items.
        let d2 = items[4]
        _ = items.moveChecklistItem(id: d2.id, toIndex: 0)
        #expect(items.map(\.text) == ["u3", "u1", "u2", "d2", "d1"])
        #expect(items.prefix(3).allSatisfy { $0.state != .completed })
        #expect(items.suffix(2).allSatisfy { $0.state == .completed })
    }
}

@Suite struct WorkspaceTaskStatusCycleTests {
    @Test func nextCyclesRoundRobinInDeclarationOrder() {
        #expect(WorkspaceTaskStatus.todo.next == .working)
        #expect(WorkspaceTaskStatus.working.next == .needsAttention)
        #expect(WorkspaceTaskStatus.needsAttention.next == .review)
        #expect(WorkspaceTaskStatus.review.next == .done)
        #expect(WorkspaceTaskStatus.done.next == .todo)
    }

    @Test func nextVisitsEveryLaneExactlyOncePerCycle() {
        var seen: [WorkspaceTaskStatus] = []
        var status = WorkspaceTaskStatus.todo
        for _ in 0..<WorkspaceTaskStatus.allCases.count {
            seen.append(status)
            status = status.next
        }
        #expect(Set(seen).count == WorkspaceTaskStatus.allCases.count)
        #expect(status == .todo)
    }
}
