import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite struct WorkspaceChecklistTests {
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

    @Test func setStateByIdUpdatesOnlyThatItem() {
        var items = [
            WorkspaceChecklistItem(text: "a"),
            WorkspaceChecklistItem(text: "b"),
        ]
        let updatedKnown = items.setChecklistItemState(id: items[1].id, state: .inProgress)
        #expect(updatedKnown)
        #expect(items[0].state == .pending)
        #expect(items[1].state == .inProgress)
        let updatedUnknown = items.setChecklistItemState(id: UUID(), state: .completed)
        #expect(!updatedUnknown)
    }

    @Test func removeByIdAndClear() {
        var items = [
            WorkspaceChecklistItem(text: "a"),
            WorkspaceChecklistItem(text: "b"),
        ]
        let removedKnown = items.removeChecklistItem(id: items[0].id)
        #expect(removedKnown)
        #expect(items.map(\.text) == ["b"])
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
        let item = WorkspaceChecklistItem(text: "ship it", state: .inProgress, origin: .agent)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(WorkspaceChecklistItem.self, from: data)
        #expect(decoded == item)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("in-progress"))
    }
}
