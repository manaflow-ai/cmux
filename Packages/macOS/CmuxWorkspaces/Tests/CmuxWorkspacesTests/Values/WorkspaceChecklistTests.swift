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

    @Test func setTextByIdNormalizesAndRejectsEmpty() {
        var items = [
            WorkspaceChecklistItem(text: "a"),
            WorkspaceChecklistItem(text: "b"),
        ]
        let edited = items.setChecklistItemText(id: items[1].id, text: "  b revised  \n")
        #expect(edited)
        #expect(items[1].text == "b revised")
        #expect(items[0].text == "a")
        let emptyEdit = items.setChecklistItemText(id: items[1].id, text: "   ")
        #expect(!emptyEdit)
        #expect(items[1].text == "b revised")
        let unknownEdit = items.setChecklistItemText(id: UUID(), text: "x")
        #expect(!unknownEdit)
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

    @Test func completingAnItemMovesItAfterUncompletedInStorage() {
        var items = [
            WorkspaceChecklistItem(text: "a"),
            WorkspaceChecklistItem(text: "b"),
            WorkspaceChecklistItem(text: "c"),
        ]
        // Complete the first item; storage must re-partition so it sits last.
        _ = items.setChecklistItemState(id: items[0].id, state: .completed)
        #expect(items.map(\.text) == ["b", "c", "a"])
        #expect(items.last?.state == .completed)
        // Un-completing moves it back to the end of the uncompleted run.
        _ = items.setChecklistItemState(id: items[2].id, state: .pending)
        #expect(items.allSatisfy { $0.state != .completed })
        #expect(items.map(\.text) == ["b", "c", "a"])
    }

    @Test func moveReordersWithinCompletionGroupOnly() {
        var items = [
            WorkspaceChecklistItem(text: "u1"),
            WorkspaceChecklistItem(text: "u2"),
            WorkspaceChecklistItem(text: "u3"),
            WorkspaceChecklistItem(text: "d1", state: .completed),
            WorkspaceChecklistItem(text: "d2", state: .completed),
        ]
        // Move u3 to the front: reorders within the uncompleted run.
        _ = items.moveChecklistItem(id: items[2].id, toIndex: 0)
        #expect(items.map(\.text) == ["u3", "u1", "u2", "d1", "d2"])
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
