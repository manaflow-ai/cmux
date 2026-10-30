import Foundation
import Testing
@testable import MessagesLabHome

/// The Chief's plan (Leo 2026-10-20): each subagent's step reads working, waiting on CI or landed
/// from its agent and its pull requests, the same in the inspector and in a reply's plan card.
@Suite struct ChiefPlanTests {
    func pr(_ state: ChiefPlanPullRequest.State, _ checks: ChiefPlanPullRequest.Checks, _ number: Int = 1) -> ChiefPlanPullRequest {
        ChiefPlanPullRequest(url: "https://github.com/manaflow-ai/cmux/pull/\(number)", number: number, state: state, checks: checks)
    }

    @Test func aLiveTurnWinsOverItsPullRequest() {
        #expect(ChiefPlanStep.state(agent: .working, pullRequests: [pr(.open, .failing)]) == .working)
        #expect(ChiefPlanStep.state(agent: .input, pullRequests: []) == .needsInput)
    }

    @Test func anIdleAgentReadsItsPullRequests() {
        #expect(ChiefPlanStep.state(agent: .idle, pullRequests: []) == .done)
        #expect(ChiefPlanStep.state(agent: .idle, pullRequests: [pr(.open, .pending)]) == .waitingOnCI)
        #expect(ChiefPlanStep.state(agent: .idle, pullRequests: [pr(.open, .failing)]) == .ciFailed)
        #expect(ChiefPlanStep.state(agent: .idle, pullRequests: [pr(.open, .passing)]) == .inReview)
        #expect(ChiefPlanStep.state(agent: nil, pullRequests: [pr(.merged, .passing)]) == .landed)
        #expect(ChiefPlanStep.state(agent: .idle, pullRequests: [pr(.merged, .passing), pr(.open, .pending, 2)]) == .waitingOnCI)
    }

    @Test func aFailedAgentWithoutAPullRequestFailed() {
        #expect(ChiefPlanStep.state(agent: .failed, pullRequests: []) == .failed)
        #expect(ChiefPlanStep.state(agent: .lost, pullRequests: [pr(.merged, .passing)]) == .landed)
    }

    @Test func pullRequestLinksAreKeyedByRepositoryAndNumber() {
        #expect(ChiefPlanPullRequest.key("https://github.com/manaflow-ai/cmux/pull/22590") == "manaflow-ai/cmux#22590")
        #expect(ChiefPlanPullRequest.key("https://github.com/Manaflow-AI/cmux/pull/22590/files") == "manaflow-ai/cmux#22590")
        #expect(ChiefPlanPullRequest.key("https://github.com/manaflow-ai/cmux/issues/22590") == nil)
        #expect(ChiefPlanPullRequest.key("https://example.com/a/b/pull/1") == nil)
        #expect(ChiefPlanPullRequest(link: "https://github.com/manaflow-ai/cmux/pull/7#x")?.number == 7)
    }

    @Test func stepsAreFoundByOwnerAndPullRequest() {
        let plan = ChiefPlan(steps: [
            ChiefPlanStep(id: "a12", title: "Train design", owner: "a12", state: .working),
            ChiefPlanStep(id: "a4", title: "Drop-back", owner: "a4", state: .waitingOnCI, pullRequests: [pr(.open, .pending, 22590)]),
        ])
        #expect(plan.step(owner: "A12")?.title == "Train design")
        #expect(plan.step(pullRequest: "https://github.com/manaflow-ai/cmux/pull/22590/checks")?.owner == "a4")
        #expect(plan.activeCount == 2)
        #expect(plan.counts[.waitingOnCI] == 1)
    }
}
