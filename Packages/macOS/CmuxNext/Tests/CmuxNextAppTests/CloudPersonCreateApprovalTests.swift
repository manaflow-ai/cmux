@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A create the person started (the composer's Cloud send, a menu, the palette) is their
/// confirmation: when the backend holds it for the G8 approval, the flow answers that request
/// as the person with no second "Create a Cloud machine?" prompt. A create nobody started still
/// asks first, and a no sends nothing.
@MainActor @Suite(.serialized) struct CloudPersonCreateApprovalTests {
    @MainActor final class Calls {
        var ops: [String] = []
        var prompts: [CloudMachineCreateFlow.Prompt] = []
        var approved: [String] = []
        var pending = true
        var confirms = true
    }

    private nonisolated static let machine: JSONValue = .object(["id": .string("vm_00000000000000000009"), "status": .string("provisioning")])

    private func flow(_ calls: Calls) -> CloudMachineCreateFlow {
        CloudMachineCreateFlow(
            run: { op, _, _, _ in
                await MainActor.run { calls.ops.append(op) }
                if await MainActor.run(body: { calls.pending }) {
                    throw CloudAppOpFailure(code: CloudAppOpFailure.approvalPending, message: "", details: .object(["request": .string("apr_1")]))
                }
                return .object(["machine": Self.machine])
            },
            confirm: { prompt in calls.prompts.append(prompt); return calls.confirms },
            approve: { request, _, _ in calls.approved.append(request); calls.pending = false },
            pause: { _ in })
    }

    @Test func aPersonsCreateHeldForApprovalIsAnsweredWithNoSecondPrompt() async throws {
        let calls = Calls()
        let made = try await flow(calls).create(name: nil, startedByPerson: true)
        #expect(made == Self.machine)
        #expect(calls.prompts.isEmpty, "the person's own click is the confirmation")
        #expect(calls.approved == ["apr_1"])
        #expect(calls.ops == ["cloud.machine.create", "cloud.machine.create"])
    }

    @Test func aCreateNobodyStartedAsksOnceThenAnswersTheHold() async throws {
        let calls = Calls()
        _ = try await flow(calls).create(name: nil, startedByPerson: false, askedBy: "agent-1")
        #expect(calls.prompts.count == 1)
        if case .agentRequest = calls.prompts.first {} else { Issue.record("expected the agent request prompt, got \(calls.prompts)") }
        #expect(calls.approved == ["apr_1"])
    }

    @Test func aDeclinedAgentRequestSendsNothing() async throws {
        let calls = Calls()
        calls.confirms = false
        await #expect(throws: CloudMachineCreateFlow.Failure.declined) {
            try await flow(calls).create(name: nil, startedByPerson: false, askedBy: "agent-1")
        }
        #expect(calls.ops.isEmpty)
        #expect(calls.approved.isEmpty)
    }
}
