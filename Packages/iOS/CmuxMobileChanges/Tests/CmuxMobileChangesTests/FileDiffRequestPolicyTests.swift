import Testing

@testable import CmuxMobileChanges

@Suite struct FileDiffRequestPolicyTests {
    @Test func cancellationErrorPublishesUnlessTheTaskWasCancelled() {
        let policy = RecoverableCancellationErrorPolicy()

        #expect(policy.shouldPublishFailure(taskIsCancelled: false))
        #expect(!policy.shouldPublishFailure(taskIsCancelled: true))
    }

    @Test func beginningANewRequestInvalidatesEveryOlderGeneration() {
        var generations = FileDiffRequestGeneration()
        let load = generations.begin()
        let showMore = generations.begin()
        let expansion = generations.begin()

        #expect(!generations.isCurrent(load))
        #expect(!generations.isCurrent(showMore))
        #expect(generations.isCurrent(expansion))
    }

    @Test func pageScopeCancellationInvalidatesTheActiveGeneration() {
        var generations = FileDiffRequestGeneration()
        let active = generations.begin()

        generations.invalidate()

        #expect(!generations.isCurrent(active))
    }
}
