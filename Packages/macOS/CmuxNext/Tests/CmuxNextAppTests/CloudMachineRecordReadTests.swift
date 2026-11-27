@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// `cloud machine-status` and `cloud handoff` on the app server link read the machine where it was
/// made (`cloud.machine.get`), never `/api/vm`, which answered a Worker machine made seconds earlier
/// "Cloud VM vm_… was not found." (chat-5ea8b40b, 2026-11-03).
@Suite
struct CloudMachineRecordReadTests {
    actor Sent {
        var calls: [(op: String, args: CmuxNextDaemon.JSONValue, key: String?, origin: AppsRunRequest.Origin)] = []
        func record(_ op: String, _ args: CmuxNextDaemon.JSONValue, _ key: String?, _ origin: AppsRunRequest.Origin) {
            calls.append((op, args, key, origin))
        }
    }

    @Test func theAppServerRecordIsReadThroughCloudMachineGet() async throws {
        let sent = Sent()
        let ops: CloudAppOp = { op, args, key, origin in
            await sent.record(op, args, key, origin)
            return .object(["id": .string("vm_6da0bc3216ca64213a09"), "status": .string("failed"), "name": .string("chat-5ea8b40b")])
        }
        let machine = try await CloudService.appServerRecord("vm_6da0bc3216ca64213a09", ops: ops)
        #expect(machine.id == "vm_6da0bc3216ca64213a09")
        #expect(machine.status == .failed)
        let calls = await sent.calls
        #expect(calls.count == 1)
        #expect(calls.first?.op == "cloud.machine.get")
        #expect(calls.first?.args["machine"]?.stringValue == "vm_6da0bc3216ca64213a09")
        #expect(calls.first?.key == nil)
        #expect(calls.first?.origin == .script)
    }

    @Test func anAnswerWithNoMachineIsABadResponse() async {
        await #expect(throws: CloudAppOpFailure.self) {
            _ = try await CloudService.appServerRecord("vm_a", ops: { _, _, _, _ in .object([:]) })
        }
    }

    @Test func aWorkerMachineStatusCarriesItsRecordState() {
        #expect(CloudMachineStats(state: "running").state == "running")
        #expect(CloudMachineStats(state: "running").cpus == nil)
    }
}
