import AppKit
@testable import CmuxNextPages
@testable import CmuxNextWakeups
import Testing

/// The claim's fallback is a ``MainDeadline`` on the page's deadline scheduler (p06-scheduler-336): a person waits on
/// the claimed page (opening Settings), so the fallback is visible work at its due time, and a claim the document never
/// answers reloads when that deadline's task runs, not before.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageClaimDeadlineTests {
    @Test func anUnansweredClaimReloadsInTheVisibleTaskOfItsDeadline() async throws {
        let rig = LifecycleDeadlineRig()
        let recipe = try #require(PageWebView.pooledHostRecipe(.settings))
        let view = PageWebView(recipe: recipe, deadlines: rig.scheduler)
        defer { view.close() }

        // The parked document has not loaded, so the claim's page call waits for an answer that never comes.
        view.claimDocument(documentAttributes: [:])
        let deadline = view.claimState.deadline
        #expect(view.claimState.pending)
        #expect(deadline.isScheduled)
        #expect(deadline.workClass == .visible, "a claim a person waits on is not visible work")
        await Task.yield()
        #expect(view.lastClaim == nil, "the claim ended before its deadline")

        // The wake posts the fallback and the frame runs it: the claim times out and the document reloads.
        rig.fire()
        #expect(view.lastClaim?.path == .timedOut)
        #expect(!view.claimState.pending)
        #expect(!deadline.isScheduled)
    }
}
