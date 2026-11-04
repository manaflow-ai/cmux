import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A CloudDO machine has a vm_<20> id: settings must use the app server,
/// preserving its identity and the server's acknowledgement (HQ brief 09).
@Suite struct CloudMachineSettingsTests {
    private actor Calls {
        struct Call: Sendable {
            let op: String
            let args: JSONValue
            let key: String?
            let origin: AppsRunRequest.Origin
        }
        private(set) var recorded: [Call] = []
        func add(_ op: String, _ args: JSONValue, _ key: String?, _ origin: AppsRunRequest.Origin) {
            recorded.append(Call(op: op, args: args, key: key, origin: origin))
        }
    }

    @Test func renameUsesCloudDOIdAndAcknowledgesTheNewName() async throws {
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", calls = Calls()
        let ops: CloudAppOp = { op, args, key, origin in
            await calls.add(op, args, key, origin)
            return .object(["machine": .object(["id": .string(machine), "name": .string("work")])])
        }
        try await CloudMachineSettings.rename(machine, to: "work", ops: ops)
        let call = try #require(await calls.recorded.first)
        #expect(call.op == "cloud.machine.rename")
        #expect(call.args["machine"]?.stringValue == machine)
        #expect(call.args["name"]?.stringValue == "work")
        #expect(call.origin == .user)
        #expect(call.key != nil && !call.key!.isEmpty)
        #expect(await calls.recorded.count == 1)
    }

    @Test func idlePauseUsesCloudDOSecondsAndAcknowledgesThePolicy() async throws {
        let machine = "vm_bbbbbbbbbbbbbbbbbbbb", calls = Calls()
        let ops: CloudAppOp = { op, args, key, origin in
            await calls.add(op, args, key, origin)
            return .object(["machine": .object(["id": .string(machine),
                                                  "idle_policy": .object(["idle_seconds": .number(900)])])])
        }
        try await CloudMachineSettings.setIdlePause(machine, minutes: 15, ops: ops)
        let call = try #require(await calls.recorded.first)
        #expect(call.op == "cloud.machine.idle_policy.set")
        #expect(call.args["machine"]?.stringValue == machine)
        #expect(call.args["idle_seconds"]?.doubleValue == 900)
        #expect(call.origin == .user)
        #expect(call.key != nil && !call.key!.isEmpty)
        #expect(await calls.recorded.count == 1)
    }

    @Test func wrongMachineOrValueLeavesTheCallerUnchanged() async {
        let machine = "vm_cccccccccccccccccccc"
        await #expect(throws: CloudAppOpFailure.self) {
            try await CloudMachineSettings.rename(machine, to: "work", ops: { _, _, _, _ in
                .object(["machine": .object(["id": .string("vm_other"), "name": .string("work")])])
            })
        }
        await #expect(throws: CloudAppOpFailure.self) {
            try await CloudMachineSettings.setIdlePause(machine, minutes: 30, ops: { _, _, _, _ in
                .object(["machine": .object(["id": .string(machine),
                                              "idle_policy": .object(["idle_seconds": .number(900)])])])
            })
        }
    }

    @Test func invalidIdlePolicyNeverSendsARequest() async {
        let calls = Calls()
        await #expect(throws: CloudAppOpFailure.self) {
            try await CloudMachineSettings.setIdlePause("vm_aaaaaaaaaaaaaaaaaaaa", minutes: -1, ops: { op, args, key, origin in
                await calls.add(op, args, key, origin)
                return .object([:])
            })
        }
        #expect(await calls.recorded.isEmpty)
    }
}
