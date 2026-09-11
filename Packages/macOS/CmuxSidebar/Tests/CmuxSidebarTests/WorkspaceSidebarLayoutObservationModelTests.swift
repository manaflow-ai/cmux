import Testing

import CmuxSidebar

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorkspaceSidebarLayoutObservationModelTests {
    @Test func replaysChangeToLateSubscriber() async {
        let model = WorkspaceSidebarLayoutObservationModel()
        model.layoutDidChange()

        var iterator = model.changes().makeAsyncIterator()
        let nextChange = await iterator.next()

        #expect(nextChange != nil)
        #expect(model.changeGeneration == 1)
    }

    @Test func deliversChangesToEverySubscriber() async {
        let model = WorkspaceSidebarLayoutObservationModel()
        var first = model.changes().makeAsyncIterator()
        var second = model.changes().makeAsyncIterator()

        model.layoutDidChange()
        let firstChange = await first.next()
        let secondChange = await second.next()
        #expect(firstChange != nil)
        #expect(secondChange != nil)

        model.layoutDidChange()
        let nextFirstChange = await first.next()
        let nextSecondChange = await second.next()
        #expect(nextFirstChange != nil)
        #expect(nextSecondChange != nil)
        #expect(model.changeGeneration == 2)
    }

    @Test func coalescesPendingChanges() async throws {
        var model: WorkspaceSidebarLayoutObservationModel? = WorkspaceSidebarLayoutObservationModel()
        var iterator = try #require(model).changes().makeAsyncIterator()

        model?.layoutDidChange()
        model?.layoutDidChange()
        model?.layoutDidChange()
        model = nil

        let bufferedChange = await iterator.next()
        let afterBufferedChange = await iterator.next()
        #expect(bufferedChange != nil)
        #expect(afterBufferedChange == nil)
    }

    @Test func replaysChangeAfterSubscriberCancellation() async {
        let model = WorkspaceSidebarLayoutObservationModel()
        let stream = model.changes()
        let subscriber = Task {
            for await _ in stream {}
        }
        subscriber.cancel()
        await subscriber.value

        model.layoutDidChange()
        var replacement = model.changes().makeAsyncIterator()
        let nextChange = await replacement.next()
        #expect(nextChange != nil)
    }

    @Test func finishesAllStreamsOnTeardown() async throws {
        var model: WorkspaceSidebarLayoutObservationModel? = WorkspaceSidebarLayoutObservationModel()
        weak var releasedModel = model
        var first = try #require(model).changes().makeAsyncIterator()
        var second = try #require(model).changes().makeAsyncIterator()
        model = nil

        #expect(releasedModel == nil)
        let firstEnd = await first.next()
        let secondEnd = await second.next()
        #expect(firstEnd == nil)
        #expect(secondEnd == nil)
    }
}
