import AppKit
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextCloud
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// A Cloud machine an agent or a script asks for is created at once on a paid plan: no
/// "Create a Cloud machine?" card. The Free plan, a plan with no machines, or a full plan gets one
/// upgrade card instead (never a plain create confirm), and nothing is sent.
@MainActor @Suite(.serialized, .closesItsWindows) struct CloudCreateWithoutAskingTests {
    @MainActor final class Sent {
        var count = 0
        var prompts: [CloudMachineCreateFlow.Prompt] = []
        func send() -> String { count += 1; return "machine" }
    }

    @Test func anAgentsCreateOnAPaidPlanAsksNothing() async throws {
        let sent = Sent()
        let made = try await CloudMachineCreateFlow.legacy(name: "builder", startedByPerson: false, gate: { .allowed },
                                                           confirm: { sent.prompts.append($0); return true },
                                                           create: { sent.send() })
        #expect(made == "machine")
        #expect(sent.count == 1, "the agent's create was not sent")
        #expect(sent.prompts.isEmpty, "a paid-plan agent create still asked: \(sent.prompts)")
    }

    /// An agent's create that the plan gate refuses shows no card and opens no pricing page: the agent gets the refusal as its error.
    @Test func anAgentsCreateOnTheFreePlanShowsNoUpgradeCard() async throws {
        let sent = Sent()
        await #expect(throws: CloudMachineCreateFlow.Failure.upgradeRequired(.freePlan)) {
            try await CloudMachineCreateFlow.legacy(name: nil, startedByPerson: false, gate: { .upgrade(.init(reason: .freePlan)) },
                                                    confirm: { sent.prompts.append($0); return false },
                                                    create: { sent.send() })
        }
        #expect(sent.count == 0, "a Free-plan create went out")
        #expect(sent.prompts.isEmpty, "an agent's refused create showed an upgrade prompt: \(sent.prompts)")
    }

    /// A refused person's create sends nothing and shows no prompt here: it throws, and ``CloudService/createMachine``
    /// shows the cap card (``CloudMachineCap``: Upgrade or Run on This Mac on a free plan).
    @Test func theFreePlanSendsNothingAndLeavesTheCardToTheCapCard() async throws {
        let sent = Sent()
        await #expect(throws: CloudMachineCreateFlow.Failure.upgradeRequired(.freePlan)) {
            try await CloudMachineCreateFlow.legacy(name: nil, startedByPerson: true, gate: { .upgrade(.init(reason: .freePlan)) },
                                                    confirm: { sent.prompts.append($0); return false },
                                                    create: { sent.send() })
        }
        #expect(sent.count == 0, "a Free-plan create went out")
        #expect(sent.prompts.isEmpty, "the flow prompted: \(sent.prompts)")
    }

    @Test func aServerPlanRefusalThrowsForTheCapCard() async throws {
        let sent = Sent()
        await #expect(throws: CloudMachineCreateFlow.Failure.upgradeRequired(.server)) {
            try await CloudMachineCreateFlow.legacy(name: nil, startedByPerson: true, gate: { .allowed },
                                                    confirm: { sent.prompts.append($0); return false },
                                                    create: { () async throws -> String in throw CloudAPIError.http(status: 402, code: "vm_active_limit_exceeded", message: "full") })
        }
        #expect(sent.prompts.isEmpty)
        // cmux#32710: the pool refusal is the classic one a Pause can lift (the pool counts only running machines).
        await #expect(throws: CloudMachineCreateFlow.Failure.upgradeRequired(.pool)) {
            try await CloudMachineCreateFlow.legacy(name: nil, startedByPerson: true, gate: { .allowed }, confirm: { _ in false },
                                                    create: { () async throws -> String in throw CloudAPIError.http(status: 402, code: "vm_resource_pool_exceeded", message: "full") })
        }
    }

    @Test func gateReadsThePlanLimits() {
        #expect(CloudMachineCreateFlow.gate(nil) == .allowed, "unknown limits must leave the server to decide")
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 5, activeVmCount: 1, planId: "pro")) == .allowed)
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 0, activeVmCount: 0, planId: "free")) == .upgrade(.init(reason: .freePlan)))
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: nil, activeVmCount: 0, planId: "free")) == .upgrade(.init(reason: .freePlan)))
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 2, activeVmCount: 2, planId: "go")) == .upgrade(.init(reason: .atLimit(2))))
        // The app-server link's backend pauses the person's idle machine at the cap itself: the create goes out.
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 2, activeVmCount: 2, planId: "go"), makesRoom: true) == .allowed)
        #expect(CloudMachineCreateFlow.gate(.init(maxActiveVms: 0, activeVmCount: 0, planId: "free"), makesRoom: true) == .upgrade(.init(reason: .freePlan)))
    }
}
