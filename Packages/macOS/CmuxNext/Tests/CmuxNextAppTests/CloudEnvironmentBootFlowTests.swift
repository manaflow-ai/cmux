@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A machine in a Cloud environment (plans/cmux-next/cloud-environments-DESIGN.md §5) is
/// `cloud.environment.boot` through the same create flow: one key, origin `user`, and the G8
/// approval answered for exactly the op that was sent. Build and delete use the same approval loop.
@MainActor @Suite(.serialized) struct CloudEnvironmentBootFlowTests {
    @MainActor final class Calls {
        var ops: [(op: String, args: JSONValue, key: String?)] = []
        var approved: [(request: String, op: String)] = []
        var pending = true
    }

    private nonisolated static let machine: JSONValue = .object(["id": .string("vm_00000000000000000009"), "status": .string("provisioning")])

    private func flow(_ calls: Calls) -> CloudMachineCreateFlow {
        CloudMachineCreateFlow(
            run: { op, args, key, _ in
                await MainActor.run { calls.ops.append((op, args, key)) }
                if await MainActor.run(body: { calls.pending }) {
                    throw CloudAppOpFailure(code: CloudAppOpFailure.approvalPending, message: "", details: .object(["request": .string("apr_1")]))
                }
                return .object(["machine": Self.machine, "boot": .string("snapshot")])
            },
            confirm: { _ in true },
            approve: { request, op, _ in calls.approved.append((request, op)); calls.pending = false },
            pause: { _ in })
    }

    @Test func anEnvironmentCreateBootsTheEnvironmentAndApprovesThatOp() async throws {
        let calls = Calls()
        let made = try await flow(calls).create(name: nil, startedByPerson: true, environment: "env_00000000000000000001")
        #expect(made == Self.machine)
        #expect(calls.ops.map(\.op) == ["cloud.environment.boot", "cloud.environment.boot"])
        #expect(calls.ops.first?.args["environment"]?.stringValue == "env_00000000000000000001")
        #expect(Set(calls.ops.compactMap(\.key)).count == 1, "every retry reuses the one key")
        #expect(calls.approved.map(\.op) == ["cloud.environment.boot"])
    }

    @Test func aPlainCreateIsStillCloudMachineCreate() async throws {
        let calls = Calls()
        calls.pending = false
        _ = try await flow(calls).create(name: "box", startedByPerson: true)
        #expect(calls.ops.map(\.op) == ["cloud.machine.create"])
        #expect(calls.ops.first?.args["environment"] == nil)
    }

    @Test func buildAndDeleteGoThroughTheSameApprovalLoop() async throws {
        let calls = Calls()
        let answer = try await flow(calls).approvedCall("cloud.environment.build", args: .object(["environment": .string("env_00000000000000000001")]),
                                                         confirm: { true })
        #expect(answer["machine"] != nil)
        #expect(calls.ops.map(\.op) == ["cloud.environment.build", "cloud.environment.build"])
        #expect(calls.approved.map(\.op) == ["cloud.environment.build"])
    }

    @Test func aDeclinedConfirmationSendsNothingMore() async throws {
        let calls = Calls()
        await #expect(throws: CloudMachineCreateFlow.Failure.declined) {
            try await flow(calls).approvedCall("cloud.environment.delete", args: .object(["environment": .string("env_00000000000000000001")]),
                                               confirm: { false })
        }
        #expect(calls.ops.count == 1)
        #expect(calls.approved.isEmpty)
    }
}
