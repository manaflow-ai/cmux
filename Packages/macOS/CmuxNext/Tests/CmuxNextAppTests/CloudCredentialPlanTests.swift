import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudCredentialPlanTests {
    @Test func confirmationIsRequiredBeforeProducingSteps() {
        #expect(throws: (any Error).self) {
            try CloudCredentialPlan(machineID: "vm-plan", confirmed: false)
        }
    }

    @Test func planDescribesNewClaudeTokenAndTargetCodexLogin() throws {
        let fields = try CloudCredentialPlan(machineID: "vm-plan", confirmed: true).fields
        #expect(fields["machine_id"] == .string("vm-plan"))
        #expect(fields["status"] == .string("plan_only"))
        #expect(fields["credentials_transferred"] == .bool(false))
        #expect(fields["automatic_transfer_available"] == .bool(false))
        #expect(fields["transfers"] == .array([]))
        guard case .object(let claude) = fields["claude"], case .object(let codex) = fields["codex"] else {
            Issue.record("both provider plans must be present")
            return
        }
        #expect(claude["local_command"] == .string("claude setup-token"))
        #expect(claude["credential_kind"] == .string("new_claude_oauth_token"))
        #expect(claude["destination_environment_variable"] == .string("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(claude["automatic_delivery_status"] == .string("secret_store_dependency_unavailable"))
        #expect(codex["target_command"] == .string("codex login --device-auth"))
        #expect(codex["credential_kind"] == .string("new_target_login"))
        #expect(codex["verification_command"] == .string("codex login status"))
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func confirmedAutomationStillHasToNameItsMachine(origin: ActionOrigin) {
        let f = CloudCLITargetTests.fixture()
        let registry = ActionRegistry(catalog: f.services.registry.descriptors)
        CloudCredentialPlanHandlers.bind(into: registry, context: f.context)
        let refusal = registry.capturingRefusal {
            _ = registry.perform("cloudCredentialPlan", invocation: ActionInvocation(arguments: ["confirm": .bool(true)], origin: origin))
        }
        #expect(refusal == CloudStrings.noMachine)
    }

    @Test func actionReturnsPlanForNamedMachineAndNeverConnectsIt() async throws {
        let f = CloudCLITargetTests.fixture()
        let registry = f.services.registry
        CloudCredentialPlanHandlers.bind(into: registry, context: f.context)
        let phase = f.session.linkPhase
        let run = registry.capturingRun {
            _ = registry.perform("cloudCredentialPlan", invocation: ActionInvocation(
                target: .init(kind: .machine, id: f.session.machineID), arguments: ["confirm": .bool(true)], origin: .cli))
        }
        let task = try #require(run.results.first)
        guard case .success(let fields) = await task.value else {
            Issue.record("the plan failed")
            return
        }
        #expect(fields == (try CloudCredentialPlan(machineID: f.session.machineID, confirmed: true)).fields)
        #expect(f.session.linkPhase == phase)
    }

    @Test func actionHasOnlyAnExplicitCLIEntryAndNoSecretArgument() throws {
        let f = CloudCLITargetTests.fixture()
        let descriptor = try #require(f.services.registry.descriptor(for: "cloudCredentialPlan"))
        #expect(descriptor.cliName == "cloud credential-plan")
        #expect(descriptor.targets == [.machine])
        #expect(descriptor.arguments.map(\.name) == ["confirm"])
        #expect(descriptor.surfacePlan.palette == .exempt(.credentials))
        #expect(descriptor.surfacePlan.mcp == .exempt(.credentials))
        #expect(!descriptor.isDestructive)
        #expect(descriptor.waitsForResult)
    }
}
