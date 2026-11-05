@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDaemonService
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
        /// The hold was answered elsewhere: this Mac finds its feed item closed, and the op goes on (or not).
        var closedElsewhere = false
        var answersAfterClose = true
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
            approve: { request, _, _ in
                if calls.closedElsewhere {
                    calls.pending = !calls.answersAfterClose
                    // What CloudApprovalAnswer answers when the create's own team's item is closed.
                    throw CloudApprovalAnswer.Failure.answered(request: request)
                }
                calls.approved.append(request); calls.pending = false
            },
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

    @Test func aBackendCapabilityRefusalSendsNoCreateOrApproval() async throws {
        let calls = Calls()
        var create = flow(calls)
        create.validateOptions = { _ in
            throw CloudAppOpFailure(code: "validation.invalid", message: "create option unavailable: create.bootstrap")
        }
        do {
            _ = try await create.create(name: "requested", startedByPerson: true)
            Issue.record("a refused create must not succeed")
        } catch let error as CloudAppOpFailure {
            #expect(error.code == "validation.invalid")
            #expect(error.message == "create option unavailable: create.bootstrap")
        }
        #expect(calls.ops.isEmpty)
        #expect(calls.approved.isEmpty)
    }

    @Test func aCreateNobodyStartedAsksOnceThenAnswersTheHold() async throws {
        let calls = Calls()
        _ = try await flow(calls).create(name: nil, startedByPerson: false, askedBy: "agent-1")
        #expect(calls.prompts.count == 1)
        if case .agentRequest = calls.prompts.first {} else { Issue.record("expected the agent request prompt, got \(calls.prompts)") }
        #expect(calls.approved == ["apr_1"])
    }

    @Test func aCreateNobodyStartedMayBypassTheCardWhenPolicyAllows() async throws {
        let calls = Calls()
        _ = try await flow(calls).create(name: nil, startedByPerson: false, asksFirst: false)
        #expect(calls.prompts.isEmpty)
        #expect(calls.approved == ["apr_1"])
    }

    @Test func aHoldAnsweredElsewhereFirstGoesOnWithTheSameKey() async throws {
        let calls = Calls()
        calls.closedElsewhere = true
        var recorded: [String] = []
        let made = try await flow(calls).create(name: nil, startedByPerson: true, onApproved: { recorded.append($0) })
        #expect(made == Self.machine)
        #expect(calls.prompts.isEmpty)
        #expect(recorded.isEmpty, "nothing was answered here, so nothing is recorded as answered")
        #expect(calls.ops == ["cloud.machine.create", "cloud.machine.create"])
    }

    @Test func aClosedItemWhoseHoldStaysPendingEndsStillPending() async throws {
        let calls = Calls()
        calls.closedElsewhere = true
        calls.answersAfterClose = false
        await #expect(throws: CloudMachineCreateFlow.Failure.stillPending(request: "apr_1")) {
            try await flow(calls).create(name: nil, startedByPerson: true)
        }
        #expect(calls.approved.isEmpty)
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
