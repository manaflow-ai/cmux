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

    /// A saved snapshot counts against the plan's `max_saved`: the fork drops the copy's snapshot once the child chat is
    /// open, so repeated clicks do not fail `cloud.quota.exceeded`. RED before: every click kept its snapshot.
    @Test func theCopysSnapshotIsDroppedOnceTheChildIsOpen() async throws {
        var calls: [String] = []
        let change: CloudTryAnotherApproach.MachineChange = { op, _, value, _, key in
            calls.append("\(op) \(value) \(key)")
            return op == "cloud.snapshot.create" ? "snap_1" : op == "cloud.snapshot.restore" ? "vm_child000000000000000" : nil
        }
        let fork = CloudTryAnotherApproach(
            prepare: { [plan] _, _ in plan },
            forkMachine: { plan in try await CloudTryAnotherApproach.copyMachine(plan, change: change) },
            forkTranscript: { _, _ in "child-session" },
            openChild: { _, _, _ in "child-tab" },
            dropCopy: { plan, child in await CloudTryAnotherApproach.dropSnapshot(plan, child, change: change) })
        let result = try await fork.run(chat: "parent-chat", throughSeq: 4)
        #expect(result.childMachine == "vm_child000000000000000")
        #expect(calls.last == "cloud.snapshot.delete snap_1 try-parent-session-4:drop")
    }

    @Test func aFailedDropDoesNotFailTheFork() async throws {
        await CloudTryAnotherApproach.dropSnapshot(plan, .init(id: "snap_1", harness: "codex", state: "ready", machineId: "vm_c", error: nil)) { _, _, _, _, _ in
            throw NSError(domain: "cloud", code: 1)
        }
        var called = false
        await CloudTryAnotherApproach.dropSnapshot(plan, .init(id: "", harness: "codex", state: "failed", machineId: nil, error: nil)) { _, _, _, _, _ in
            called = true; return nil
        }
        #expect(!called)
    }
}
