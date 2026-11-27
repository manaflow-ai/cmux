import CMUXMobileCore
import CmuxMobileShellModel
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite struct TodoSurfaceModelTests {
    @Test func successfulMutationsStayOptimisticAndRespectCompletionPartitions() async {
        let pendingID = "pending"
        let secondPendingID = "second-pending"
        let completedID = "completed"
        var received: [MobileTodoMutation] = []
        let model = TodoSurfaceModel(
            snapshot: MobileTodoSnapshot(
                status: .todo,
                statusHidden: true,
                items: [
                    item(id: pendingID, state: .pending),
                    item(id: secondPendingID, state: .inProgress),
                    item(id: completedID, state: .completed),
                ]
            ),
            mutate: { received.append($0) }
        )

        #expect(await model.perform(.setState(itemID: pendingID, state: .completed)))
        #expect(model.snapshot.items.map(\.id) == [secondPendingID, completedID, pendingID])

        #expect(await model.perform(.move(itemID: pendingID, toIndex: 1)))
        #expect(model.snapshot.items.map(\.id) == [secondPendingID, pendingID, completedID])

        #expect(await model.perform(.edit(itemID: secondPendingID, text: "  Edited  ")))
        #expect(model.snapshot.items.first?.text == "Edited")

        #expect(await model.perform(.remove(itemID: completedID)))
        #expect(model.snapshot.items.map(\.id) == [secondPendingID, pendingID])

        #expect(await model.perform(.setStatus(.review)))
        #expect(model.snapshot.status == .review)
        #expect(model.snapshot.statusHidden == false)
        #expect(await model.perform(.cycleStatus))
        #expect(model.snapshot.status == .done)
        #expect(received.count == 6)
    }

    @Test func failedMutationRollsBackAndPresentsAnError() async {
        let original = MobileTodoSnapshot(
            status: .working,
            statusHidden: false,
            items: [item(id: "item", state: .pending)]
        )
        let model = TodoSurfaceModel(snapshot: original) { _ in
            throw CancellationError()
        }

        #expect(await model.perform(.edit(itemID: "item", text: "Changed")) == false)
        #expect(model.snapshot == original)
        #expect(model.showsMutationError)
        #expect(model.pendingRequestID == nil)
    }

    @Test func invalidOrOverLimitAddsNeverReachTheRPCMutation() async {
        var mutationCount = 0
        let items = (0..<50).map { item(id: "item-\($0)", state: .pending) }
        let model = TodoSurfaceModel(
            snapshot: MobileTodoSnapshot(status: .todo, statusHidden: false, items: items),
            mutate: { _ in mutationCount += 1 }
        )

        #expect(await model.perform(.add(text: "One too many")) == false)
        #expect(await model.perform(.add(text: "   ")) == false)
        #expect(mutationCount == 0)
        #expect(model.snapshot.items == items)
    }

    private func item(id: String, state: MobileTodoItemState) -> MobileTodoItem {
        MobileTodoItem(id: id, text: id, state: state, origin: .user)
    }
}
