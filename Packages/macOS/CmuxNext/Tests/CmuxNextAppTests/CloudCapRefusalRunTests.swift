import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// cmux#32725: a classic create the server refuses for the plan (HTTP 402), or the stale plan gate refuses, shows
/// the cap card only on the person's own run (design/cloud.md "At the machine cap", rule 5). A CLI's or agent's
/// `cloud new-workspace` / `new-machine` hears the refusal at once, a plan refusal as `cloud.plan.required`,
/// instead of `pending: true` after 30 s while a card it cannot answer waits.
@MainActor @Suite(.serialized)
struct CloudCapRefusalRunTests {
    final class Cards { var shown = 0 }

    /// A CLI's `user` origin over the control socket, or a run an agent chat asked for, is not the person's own.
    @Test func onlyThePersonsOwnRunGetsTheCard() {
        var cli = ActionInvocation(origin: .user)
        cli.viaControlSocket = true
        var agent = ActionInvocation(origin: .user)
        agent.callerAgentSession = "chat-1"
        #expect(ActionInvocation(origin: .user).isPersonsOwnRun)
        #expect(!cli.isPersonsOwnRun)
        #expect(!agent.isPersonsOwnRun)
        #expect(!ActionInvocation(origin: .cli).isPersonsOwnRun)
    }

    /// The service's create (``CloudService/createMachine``): the cap step around a create the plan `gate` or the
    /// server refuses, its card shown when `startedByPerson && capCard`, answered by `cards` (Not now).
    private func flow(_ creations: CloudCreations, capCard: Bool, gate: CloudMachineCreateFlow.Gate = .allowed, refusing error: any Error,
                      cards: Cards) -> CloudCreationFlow {
        CloudCreationFlow(
            creations: creations,
            create: { _ in
                try await CloudMachineCap.creating(person: capCard, cap: { error in
                    guard case CloudMachineCreateFlow.Failure.upgradeRequired(let reason) = error else { return CloudMachineCap.refusal(error) }
                    return CloudMachineCap.plan(freePlan: reason == .freePlan, pauseFrees: reason == .pool, machines: [], user: nil)
                }, choose: { _ in cards.shown += 1; return nil }, pause: { _ in Issue.record("paused") }) { _ in
                    if case .upgrade(let need) = gate { throw CloudMachineCreateFlow.Failure.upgradeRequired(need.reason) }
                    throw error
                }
            },
            open: { _ in "" },
            show: { _, _ in },
            startedByPerson: true
        )
    }

    /// The CLI's answer for a create `flow` runs over the app's creations, as `cloud new-machine` reports it.
    private func report(_ flow: (CloudCreations) -> CloudCreationFlow) async throws -> ActionWorkFailure? {
        let f = CloudCLITargetTests.fixture()
        let creation = flow(f.services.cloud.creations).start(in: nil, existing: nil)
        defer { f.services.cloud.creations.remove(creation) }
        let run = f.services.registry.capturingRun { CloudHandlers.reportCreatedMachine(creation, f.context, wait: .seconds(20)) }
        let task = try #require(run.results.first)
        guard case .failure(let failure) = await task.value else { return nil }
        return failure
    }

    @Test func aCLIRunRefusedByTheServerFailsAtOnceWithNoCard() async throws {
        let cards = Cards()
        let started = ContinuousClock.now
        let failure = try await report { flow($0, capCard: false, refusing: CloudMachineCreateFlow.Failure.upgradeRequired(.server), cards: cards) }
        #expect(cards.shown == 0, "a CLI's create showed the cap card")
        #expect(failure?.message.contains(CloudStrings.upgradeRequired) == true, "the refusal did not reach the caller: \(String(describing: failure))")
        #expect(ContinuousClock.now - started < .seconds(10), "the refusal waited instead of answering at once")
    }

    @Test func aCLIRunAFreePlanRefusesAnswersPlanRequired() async throws {
        let cards = Cards()
        let failure = try await report { flow($0, capCard: false, gate: .upgrade(.init(reason: .freePlan)), refusing: ActionFailure(message: "unreached"), cards: cards) }
        #expect(cards.shown == 0)
        #expect(failure?.code == CloudHandlers.planRequiredCode)
        #expect(failure?.message.contains("(plan: pro)") == true)
    }

    @Test func thePersonsRunRefusedByTheServerShowsTheCard() async throws {
        let cards = Cards()
        let failure = try await report { flow($0, capCard: true, refusing: CloudMachineCreateFlow.Failure.upgradeRequired(.server), cards: cards) }
        #expect(cards.shown == 1, "the person's own create showed no cap card")
        #expect(failure != nil, "Not now on the card leaves the create refused")
    }
}
