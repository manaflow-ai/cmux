import Foundation
import Testing
@testable import CmuxMobileChief

/// The phone's Cloud Machines page (CMUX-487): the account's own `cloud.machine.*`,
/// `cloud.snapshot.*` and `cloud.plan.get` calls at the HTTP boundary. An extension of
/// ``AccountCloudTests`` so it shares that suite's serialized scripted service.
extension AccountCloudTests {
    enum Machines {
        static let machines = #"{"value":{"revision":"r","next_cursor":null,"machines":[{"id":"vm_aaaaaaaaaaaaaaaaaaaa","team":"team_1","creator":"user_1","name":"Build box","size":{"cpu":2,"memory_mb":4096,"disk_mb":16384},"status":"running","image":{"id":"img","daemon_version":null},"host":null,"classic":false,"created_at":1000,"last_active_at":2000,"idle_policy":{"idle_seconds":1800},"error":null,"hourly_rate_usd":0.1,"running_since":0,"revision":"1"},{"id":"vm_bbbbbbbbbbbbbbbbbbbb","team":"team_1","creator":"user_1","name":null,"size":{"cpu":2,"memory_mb":8192,"disk_mb":16384},"status":"paused","image":{"id":"img","daemon_version":null},"host":null,"classic":false,"created_at":3000,"last_active_at":null,"idle_policy":{"idle_seconds":0},"error":null,"pause_reason":"idle","paused_hourly_rate_usd":0.002,"keep":true,"revision":"2"}]}}"#
        static let plan = #"{"value":{"plan_id":"pro","upgrade_plan":null,"limits":{"max_active":3,"max_saved":10,"memory_options_mb":[4096,8192,16384],"locked_memory_options_mb":[16384],"vm_hours_included":100},"usage":{"active":1,"saved":2,"vm_hours_used":12.5,"period_end":0}}}"#
        static let snapshots = #"{"value":{"snapshots":[{"id":"snap_aaaaaaaaaaaaaaaaaaaa","machine":"vm_aaaaaaaaaaaaaaaaaaaa","name":"before upgrade","size_mb":2048,"status":"ready","created_at":5000,"revision":"1"},{"id":"snap_bbbbbbbbbbbbbbbbbbbb","machine":"vm_cccccccccccccccccccc","name":null,"size_mb":1024,"status":"ready","created_at":4000,"archive_of":{"machine":"vm_cccccccccccccccccccc","name":"Old box","until":9000},"revision":"2"}]}}"#

        static var reads: [String: (Int, String)] {
            ["cloud.machine.list": (200, machines), "cloud.plan.get": (200, plan), "cloud.snapshot.list": (200, snapshots)]
        }

        @MainActor static func model() -> CloudMachinesModel {
            let account = AccountCloudTests.account()
            let model = CloudMachinesModel { account }
            model.newKey = { "k" }
            return model
        }
    }

    @Test func cloudMachinesPlanAndSnapshotsLoad() async throws {
        Service.reset(Machines.reads)
        let model = Machines.model()
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.sorted.map(\.id) == ["vm_aaaaaaaaaaaaaaaaaaaa", "vm_bbbbbbbbbbbbbbbbbbbb"])
        let running = try #require(model.machine("vm_aaaaaaaaaaaaaaaaaaaa"))
        #expect(running.title == "Build box" && running.idlePauseMinutes == 30 && running.size.memoryMB == 4096)
        let paused = model.machine("vm_bbbbbbbbbbbbbbbbbbbb")
        #expect(paused?.title == "vm_bbbbbbbbbbbbbbbbbbbb" && paused?.keep == true && paused?.note == "Paused after it sat idle.")
        #expect(model.plan?.memoryChoicesMB == [4096, 8192])
        #expect(model.plan?.active == 1 && model.plan?.maxActive == 3)
        #expect(model.snapshots(of: "vm_aaaaaaaaaaaaaaaaaaaa").map(\.id) == ["snap_aaaaaaaaaaaaaaaaaaaa"])
        #expect(model.archives.map(\.title) == ["Archive of Old box"])
        #expect(Service.lock.withLock { Service.seen.allSatisfy { $0.path == "/v1/read" } })
    }

    @Test func everyCloudMachineActionIsTheAccountsOwnOp() async throws {
        let answer = #"{"value":{"machine":{"id":"vm_aaaaaaaaaaaaaaaaaaaa","status":"pausing","size":{},"idle_policy":{"idle_seconds":0}}}}"#
        var answers = Machines.reads
        for op in ["cloud.machine.create", "cloud.machine.start", "cloud.machine.pause", "cloud.machine.rename", "cloud.machine.idle_policy.set",
                   "cloud.machine.keep", "cloud.machine.resize", "cloud.machine.delete", "cloud.machine.archive_delete",
                   "cloud.snapshot.create", "cloud.snapshot.restore", "cloud.snapshot.delete"] {
            answers[op] = (200, answer)
        }
        Service.reset(answers)
        let model = Machines.model()
        await model.load()
        let running = try #require(model.machine("vm_aaaaaaaaaaaaaaaaaaaa"))
        let paused = try #require(model.machine("vm_bbbbbbbbbbbbbbbbbbbb"))

        await model.create(name: "  New box ", memoryMB: 8192)
        let create = try #require(Service.params("cloud.machine.create"))
        #expect(create["name"] as? String == "New box")
        #expect((create["size"] as? [String: Any])?["memory_mb"] as? Int == 8192)
        #expect((create["size"] as? [String: Any])?["cpu"] as? Int == 2)

        await model.pause(running)
        #expect(Service.params("cloud.machine.pause")?["machine"] as? String == running.id)
        await model.start(paused)
        #expect(Service.params("cloud.machine.start")?["machine"] as? String == paused.id)
        await model.rename(running, to: "Renamed")
        #expect(Service.params("cloud.machine.rename")?["name"] as? String == "Renamed")
        await model.setIdlePause(running, minutes: 60)
        #expect(Service.params("cloud.machine.idle_policy.set")?["idle_seconds"] as? Int == 3600)
        await model.setKeep(running, true)
        #expect(Service.params("cloud.machine.keep")?["keep"] as? Bool == true)
        await model.grow(running, memoryMB: 8192)
        #expect((Service.params("cloud.machine.resize")?["size"] as? [String: Any])?["memory_mb"] as? Int == 8192)
        await model.takeSnapshot(running, name: "snap")
        #expect(Service.params("cloud.snapshot.create")?["machine"] as? String == running.id)
        let archive = try #require(model.archives.first)
        await model.restore(archive)
        #expect(Service.params("cloud.snapshot.restore")?["snapshot"] as? String == archive.id)
        await model.deleteSnapshot(archive)
        #expect(Service.params("cloud.snapshot.delete")?["snapshot"] as? String == archive.id)
        await model.archiveAndDelete(paused)
        #expect(Service.params("cloud.machine.archive_delete")?["machine"] as? String == paused.id)
        await model.delete(running)
        #expect(Service.params("cloud.machine.delete")?["machine"] as? String == running.id)

        // Writes go to /v1/ops as the person, with a key.
        let writes = Service.lock.withLock { Service.seen.filter { $0.body["idempotency_key"] != nil } }
        #expect(writes.count == 12)
        #expect(writes.allSatisfy { $0.path == "/v1/ops" && $0.body["origin"] as? String == "user" })
        #expect(model.failure == nil)
    }

    @Test func aRefusedCloudMachineStartRollsBackAndSaysWhy() async throws {
        var answers = Machines.reads
        answers["cloud.machine.start"] = (409, #"{"error":{"code":"cloud.quota.exceeded","message":"limit"}}"#)
        Service.reset(answers)
        let model = Machines.model()
        await model.load()
        let paused = try #require(model.machine("vm_bbbbbbbbbbbbbbbbbbbb"))
        await model.start(paused)
        #expect(model.machine(paused.id)?.status == .paused)
        #expect(model.failure == "You're at your plan's machine limit. Pause or delete one first.")
    }

    @Test func aHeldCloudMachineApprovalIsANoteNotAFailure() async throws {
        var answers = Machines.reads
        answers["cloud.machine.create"] = (409, #"{"error":{"code":"approval.pending","message":"waiting"}}"#)
        Service.reset(answers)
        let model = Machines.model()
        await model.load()
        await model.create(name: "", memoryMB: nil)
        #expect(model.failure == nil)
        #expect(model.notice == "Approve it in your Feed to finish.")
        #expect(Service.params("cloud.machine.create")?["name"] == nil)
    }

    @Test func cloudMachinesSignedOutSaysSo() async {
        let model = CloudMachinesModel { nil }
        await model.load()
        #expect(model.phase == .failed("Sign in to cmux to see your Cloud machines."))
        #expect(!model.canAct)
    }

    @Test func cloudMachineGrowOnlyGoesUp() async throws {
        Service.reset(Machines.reads)
        let model = Machines.model()
        await model.load()
        let paused = try #require(model.machine("vm_bbbbbbbbbbbbbbbbbbbb"))
        await model.grow(paused, memoryMB: 4096)
        #expect(!Service.ops.contains("cloud.machine.resize"))
    }
}
