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
        let added = try WorkspaceChecklist.add("  fix the bug  \n", origin: .agent, to: &items).get()
        #expect(added.text == "fix the bug")
        #expect(added.state == .pending)
        #expect(added.origin == .agent)
        #expect(items == [added])
    }

    @Test func addRejectsEmptyAndWhitespaceOnlyText() {
        var items: [WorkspaceChecklistItem] = []
        #expect(WorkspaceChecklist.add("", to: &items) == .failure(.emptyText))
        #expect(WorkspaceChecklist.add("   \n\t", to: &items) == .failure(.emptyText))
        #expect(items.isEmpty)
    }

    @Test func addCapsTextLength() throws {
        var items: [WorkspaceChecklistItem] = []
        let long = String(repeating: "x", count: WorkspaceChecklist.maxTextLength + 100)
        let added = try WorkspaceChecklist.add(long, to: &items).get()
        #expect(added.text.count == WorkspaceChecklist.maxTextLength)
    }

    @Test func addRejectsWhenFull() {
        var items = (0..<WorkspaceChecklist.maxItems).map {
            WorkspaceChecklistItem(text: "item \($0)")
        }
        #expect(WorkspaceChecklist.add("one too many", to: &items) == .failure(.checklistFull))
        #expect(items.count == WorkspaceChecklist.maxItems)
    }

    @Test func setStateByIdUpdatesOnlyThatItem() {
        var items = [
            WorkspaceChecklistItem(text: "a"),
            WorkspaceChecklistItem(text: "b"),
        ]
        #expect(WorkspaceChecklist.setState(id: items[1].id, state: .inProgress, in: &items))
        #expect(items[0].state == .pending)
        #expect(items[1].state == .inProgress)
        #expect(!WorkspaceChecklist.setState(id: UUID(), state: .completed, in: &items))
    }

    @Test func removeByIdAndClear() {
        var items = [
            WorkspaceChecklistItem(text: "a"),
            WorkspaceChecklistItem(text: "b"),
        ]
        #expect(WorkspaceChecklist.remove(id: items[0].id, from: &items))
        #expect(items.map(\.text) == ["b"])
        #expect(!WorkspaceChecklist.remove(id: UUID(), from: &items))
        #expect(WorkspaceChecklist.clear(&items) == 1)
        #expect(items.isEmpty)
        #expect(WorkspaceChecklist.clear(&items) == 0)
    }

    @Test func progressSummaryCountsAndFirstUnchecked() {
        var items = [
            WorkspaceChecklistItem(text: "done one", state: .completed),
            WorkspaceChecklistItem(text: "doing", state: .inProgress),
            WorkspaceChecklistItem(text: "later", state: .pending),
        ]
        let summary = WorkspaceChecklist.progressSummary(of: items)
        #expect(summary.completedCount == 1)
        #expect(summary.totalCount == 3)
        #expect(summary.firstUncheckedText == "doing")

        for item in items {
            WorkspaceChecklist.setState(id: item.id, state: .completed, in: &items)
        }
        let allDone = WorkspaceChecklist.progressSummary(of: items)
        #expect(allDone.completedCount == 3)
        #expect(allDone.firstUncheckedText == nil)

        let empty = WorkspaceChecklist.progressSummary(of: [])
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
