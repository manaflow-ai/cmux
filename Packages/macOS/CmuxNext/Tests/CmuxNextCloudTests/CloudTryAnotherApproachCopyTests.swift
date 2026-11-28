import CmuxNextCloud
import Foundation
import Testing

/// cmux#56531: a Cloud chat's Try another approach copies the chat's machine with the person's own CloudDO ops
/// (`cloud.snapshot.create`, then `cloud.snapshot.restore`), as `cmux vm fork` does. RED before: it asked the platform
/// for a fork run, whose source lookup reads TeamMachines; a Cloud chat's machine is a CloudDO row with no team machine
/// record, so every Cloud chat (every harness) said "Couldn't fork this chat".
@MainActor
@Suite
struct CloudTryAnotherApproachCopyTests {
    let plan = CloudTryAnotherApproach.Plan(
        workspace: "workspace-gallery", sourceMachine: "vm_parent0000000000000", session: "parent-session",
        harness: "codex", throughSeq: 4, clientKey: "try-parent-session-4", parentLabel: "Try another approach · Gallery")

    @Test func copiesTheSourceMachineBySnapshotThenRestore() async throws {
        var calls: [String] = []
        let child = try await CloudTryAnotherApproach.copyMachine(plan) { op, arg, value, answers, _ in
            calls.append("\(op) \(arg)=\(value) -> \(answers)")
            return op == "cloud.snapshot.create" ? "snap_1" : "vm_child000000000000000"
        }
        #expect(calls == ["cloud.snapshot.create machine=vm_parent0000000000000 -> snapshot",
                          "cloud.snapshot.restore snapshot=snap_1 -> machine"])
        #expect(child.machineId == "vm_child000000000000000")
        #expect(child.harness == "codex")
        #expect(child.error == nil)
    }

    @Test func aRestoreWithNoMachineFailsTheForkWithItsReason() async throws {
        let fork = CloudTryAnotherApproach(
            prepare: { [plan] _, _ in plan },
            forkMachine: { plan in
                try await CloudTryAnotherApproach.copyMachine(plan) { op, _, _, _, _ in op == "cloud.snapshot.create" ? "snap_1" : nil }
            },
            forkTranscript: { _, _ in Issue.record("no transcript fork without a child machine"); return "" },
            openChild: { _, _, _ in Issue.record("no child chat without a child machine"); return "" })
        do {
            _ = try await fork.run(chat: "parent-chat", throughSeq: 4)
            Issue.record("the fork succeeded with no child machine")
        } catch {
            #expect(error.localizedDescription.contains("the restore answered no machine"))
        }
    }

    /// A retry of the same fork (a failed child wait, a second click) sends the same keys, so the backend answers the
    /// first attempt's snapshot and machine instead of billing another copy; another turn's fork is another copy.
    @Test func aRetryOfTheSameForkSendsTheSameKeys() async throws {
        func keys(_ plan: CloudTryAnotherApproach.Plan) async throws -> [String] {
            var keys: [String] = []
            _ = try await CloudTryAnotherApproach.copyMachine(plan) { op, _, _, _, key in
                keys.append(key); return op == "cloud.snapshot.create" ? "snap_1" : "vm_child000000000000000"
            }
            return keys
        }
        let first = try await keys(plan), retry = try await keys(plan)
        #expect(first == ["try-parent-session-4:snapshot", "try-parent-session-4:restore"])
        #expect(retry == first)
        let laterTurn = CloudTryAnotherApproach.Plan(
            workspace: plan.workspace, sourceMachine: plan.sourceMachine, session: plan.session, harness: plan.harness,
            throughSeq: 6, clientKey: "try-parent-session-6", parentLabel: plan.parentLabel)
        #expect(Set(try await keys(laterTurn)).isDisjoint(with: first))
    }

    @Test func aSnapshotWithNoIDRestoresNothing() async throws {
        var ops: [String] = []
        let child = try await CloudTryAnotherApproach.copyMachine(plan) { op, _, _, _, _ in ops.append(op); return nil }
        #expect(ops == ["cloud.snapshot.create"])
        #expect(child.machineId == nil)
    }
}
