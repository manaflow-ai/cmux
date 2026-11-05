import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// A Cloud create at the plan's machine cap (leo-workspace design/cloud.md, "At the machine cap"). Leo, 2026-11-02:
/// "you try to create a new workspace/machine past the cap, what do we wanna do? reuse existing or ask upgrade or".
@MainActor @Suite struct CloudMachineCapTests {
    static let refused = CloudAppOpFailure(code: "cmux.cloud.quota_exceeded", message: "at the cap", details: .object([
        "resource": .string("active"), "limit": .number(2), "used": .number(2),
        "busy": .array([
            .object(["machine": .string("vm_b"), "name": .string("paint"), "last_active_at": .number(1_800_000_000_000)]),
            .object(["machine": .string("vm_a"), "name": .null, "last_active_at": .number(1_700_000_000_000)]),
        ]),
    ]))

    @Test func theServersCapRefusalNamesTheBusyMachines() throws {
        let cap = try #require(CloudMachineCap.refusal(Self.refused))
        #expect(cap.busy == [
            .init(machine: "vm_b", name: "paint", lastActiveAt: Date(timeIntervalSince1970: 1_800_000_000)),
            .init(machine: "vm_a", name: "vm_a", lastActiveAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
        #expect(!cap.freePlan)
        #expect(CloudMachineCap.refusal(CloudAppOpFailure(code: "cmux.cloud.plan_required", message: "")) == nil)
        let snapshots = CloudAppOpFailure(code: "cmux.cloud.quota_exceeded", message: "", details: .object(["resource": .string("snapshots")]))
        #expect(CloudMachineCap.refusal(snapshots) == nil, "another quota is not the machine cap")
    }

    @Test func theClassicCardListsOnlyThePersonsOwnRunningMachines() {
        var mine = CloudMachine(id: "vm_mine", status: .running, displayName: "paint")
        mine.createdBy = "alice"
        var theirs = CloudMachine(id: "vm_bob", status: .running)
        theirs.createdBy = "bob"
        var paused = CloudMachine(id: "vm_paused", status: .paused)
        paused.createdBy = "alice"
        let cap = CloudMachineCap.plan(freePlan: false, pauseFrees: true, machines: [mine, theirs, paused], user: "alice")
        #expect(cap.busy.map(\.machine) == ["vm_mine"], "never a teammate's machine, nor one not running")
        #expect(CloudMachineCap.busy(machines: [mine], user: nil).isEmpty)
        #expect(CloudMachineCap.plan(freePlan: true, pauseFrees: true, machines: [mine], user: "alice") == CloudMachineCap(freePlan: true))
    }

    /// cmux#32710: the classic allowance counts paused machines, so a Pause there would free nothing: its card offers
    /// Upgrade and Run on This Mac only. Its vCPU and memory pool counts running machines alone, so that refusal keeps Pause.
    @Test func theClassicCardOffersPauseOnlyWherePausingFreesRoom() {
        var mine = CloudMachine(id: "vm_mine", status: .running, displayName: "paint")
        mine.createdBy = "alice"
        let full = CloudMachineCap.plan(freePlan: false, pauseFrees: false, machines: [mine], user: "alice")
        #expect(full == CloudMachineCap(), "a Pause that frees no slot was offered")
        #expect(!full.freePlan)
        #expect(CloudMachineCap.plan(freePlan: false, pauseFrees: true, machines: [mine], user: "alice").busy.map(\.machine) == ["vm_mine"])
    }

    /// cmux#32708: the app-server link pauses through `cloud.machine.pause`, never `/api/vm`; CloudDO answers once the
    /// slot is free, and a pause longer than its wait (`mutation.indeterminate`) is asked again with the same key.
    @Test func theAppServerPauseAsksCloudDOWithOneKeyUntilItLands() async throws {
        let sent = SentOps()
        let ops: CloudAppOp = { op, args, key, origin in
            let count = await sent.record(op: op, machine: args["machine"]?.stringValue, key: key, origin: origin)
            if count < 3 { throw CloudAppOpFailure(code: CloudMachinePower.indeterminate, message: "cut off") }
            return .object(["machine": .object(["id": .string("vm_a"), "status": .string("pausing")])])
        }
        try await CloudMachinePower.run("cloud.machine.pause", machine: "vm_a", ops: ops)
        let calls = await sent.calls
        #expect(calls.map(\.op) == Array(repeating: "cloud.machine.pause", count: 3))
        #expect(calls.allSatisfy { $0.machine == "vm_a" && $0.origin == .user })
        #expect(Set(calls.compactMap(\.key)).count == 1 && calls.allSatisfy { $0.key != nil }, "a retry made a new key")
    }

    @Test func passiveMachinePowerPreservesScriptOrigin() async throws {
        let sent = SentOps()
        try await CloudMachinePower.run("cloud.machine.start", machine: "vm_a", origin: .script, ops: { op, args, key, origin in
            _ = await sent.record(op: op, machine: args["machine"]?.stringValue, key: key, origin: origin)
            return .object([:])
        })
        #expect(await sent.calls.count == 1)
        #expect(await sent.calls.first?.origin == .script)
    }

    @Test func theAppServerPauseStopsAfterItsAttemptsAndOnAnyOtherError() async {
        let sent = SentOps()
        await #expect(throws: CloudAppOpFailure(code: CloudMachinePower.indeterminate, message: "")) {
            try await CloudMachinePower.run("cloud.machine.pause", machine: "vm_a", ops: { op, args, key, origin in
                _ = await sent.record(op: op, machine: args["machine"]?.stringValue, key: key, origin: origin)
                throw CloudAppOpFailure(code: CloudMachinePower.indeterminate, message: "")
            })
        }
        #expect(await sent.calls.count == 3)
        let other = SentOps()
        await #expect(throws: CloudAppOpFailure(code: "cmux.cloud.not_running", message: "")) {
            try await CloudMachinePower.run("cloud.machine.pause", machine: "vm_a", ops: { op, args, key, origin in
                _ = await other.record(op: op, machine: args["machine"]?.stringValue, key: key, origin: origin)
                throw CloudAppOpFailure(code: "cmux.cloud.not_running", message: "")
            })
        }
        #expect(await other.calls.count == 1)
    }

    /// Red/green for the app side: at the cap, the person's Pause pauses that machine, then the create goes again.
    @Test func atTheCapPauseOneThenCreates() async throws {
        var calls: [String] = []
        let made = try await CloudMachineCap.creating(person: true, cap: CloudMachineCap.refusal, choose: { _ in .pause("vm_a") },
                                                      pause: { calls.append("pause \($0)") }) { again in
            calls.append(again ? "create again" : "create")
            if !again { throw Self.refused }
            return "vm_new"
        }
        #expect(made == "vm_new")
        #expect(calls == ["create", "pause vm_a", "create again"])
    }

    @Test func runHereUpgradeAndNotNowCreateNothingMore() async {
        for (choice, expected) in [(CloudMachineCap.Choice.runHere, "RunHere"), (.upgrade, "refusal"), (nil, "refusal")] {
            var creates = 0
            do {
                _ = try await CloudMachineCap.creating(person: true, cap: CloudMachineCap.refusal, choose: { _ in choice }, pause: { _ in Issue.record("paused") }) { _ -> String in
                    creates += 1
                    throw Self.refused
                }
                Issue.record("created")
            } catch {
                #expect((error is CloudMachineCap.RunHere ? "RunHere" : "refusal") == expected)
            }
            #expect(creates == 1)
        }
    }

    @Test func anAgentsCreateGetsNoCard() async {
        var shown = false
        await #expect(throws: CloudAppOpFailure.self) {
            _ = try await CloudMachineCap.creating(person: false, cap: CloudMachineCap.refusal, choose: { _ in shown = true; return .pause("vm_a") },
                                                   pause: { _ in }) { _ -> String in throw Self.refused }
        }
        #expect(!shown)
    }

    @Test func aCreateThatMadeRoomNamesThePausedMachine() {
        let answer: JSONValue = .object(["machine": .object(["id": .string("vm_new")]),
                                         "made_room": .object(["machine": .object(["id": .string("vm_old"), "name": .string("paint")])])])
        #expect(CloudMachineCap.madeRoom(answer)?["id"]?.stringValue == "vm_old")
        #expect(CloudMachineCap.madeRoom(.object(["machine": .object([:])])) == nil)
    }
}

private actor SentOps {
    struct Call { var op: String; var machine: String?; var key: String?; var origin: AppsRunRequest.Origin }
    var calls: [Call] = []
    func record(op: String, machine: String?, key: String?, origin: AppsRunRequest.Origin) -> Int {
        calls.append(Call(op: op, machine: machine, key: key, origin: origin))
        return calls.count
    }
}
