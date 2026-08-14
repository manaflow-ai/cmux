import Testing

@testable import CmuxMobileShellUI

@Suite struct MobilePushMutationCompletionTests {
    @Test func onlyTheWinningResolutionReportsSuccess() async {
        let completion = MobilePushMutationCompletion()

        #expect(await completion.resolve(.completed, succeeded: true))
        #expect(!(await completion.resolve(.timedOut)))
        #expect(
            await completion.wait()
                == MobilePushMutationResult(
                    outcome: .completed,
                    succeeded: true
                )
        )
    }
}
