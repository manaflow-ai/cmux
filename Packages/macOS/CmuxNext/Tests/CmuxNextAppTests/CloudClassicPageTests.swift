import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Observation
import Testing

/// Capture run 41004738189 (a signed-in staging build on the classic link): the Cloud page said
/// "Cloud is not available until cmux reconnects." for the whole run and Retry did nothing, while
/// the CLI listed, paused and resumed the machines. The page spoke only to the Cloud app server,
/// whose credential relay the classic link never registers, so every op answered
/// `relay_unavailable`. On the classic link the page now reads Cloud's own `/api/vm` list.
@MainActor @Suite(.serialized)
struct CloudClassicPageTests {
    /// The registry's machines, observable like ``MachineRegistry/cloud``.
    @Observable @MainActor final class Machines {
        var list: [CloudMachine] = []
        var limits: CloudMachineLimits?
        var signedIn = true
        @ObservationIgnored var ran: [String] = []
    }

    @MainActor final class Seen {
        var items: [CmuxNextSettings.JSONValue] = []
    }

    static let page = PageCallContext(page: PageDescriptor.cloud.id)
    static let confirmed = PageCallContext(page: PageDescriptor.cloud.id, origin: "user", confirmed: true)

    static func backend(_ machines: Machines) -> CloudClassicPageOps.Backend {
        CloudClassicPageOps.Backend(
            signedIn: { machines.signedIn },
            team: { "team-1" },
            machines: { machines.list },
            limits: { machines.limits },
            memoryOptions: [8192, 4096],
            hasList: { true },
            lastError: { nil },
            refresh: {},
            resume: { id in
                machines.ran.append("resume \(id)")
                machines.list = machines.list.map { var m = $0; if m.id == id { m.status = .running }; return m }
            },
            pause: { id in
                machines.ran.append("pause \(id)")
                machines.list = machines.list.map { var m = $0; if m.id == id { m.status = .paused }; return m }
            },
            rename: { id, name in machines.ran.append("rename \(id) \(name)") },
            delete: { id in
                machines.ran.append("delete \(id)")
                machines.list.removeAll { $0.id == id }
            },
            create: { name, memory, key in
                machines.ran.append("create \(name ?? "") \(memory ?? 0) \(key ?? "")")
                let machine = CloudMachine(id: "vm-new", status: .provisioning, displayName: name)
                machines.list.append(machine)
                return machine
            },
            refusal: { .init(code: "cmux.cloud.failed", message: String(describing: $0)) },
            signInFirst: "sign in")
    }

    static func provider(_ machines: Machines) -> (CloudPageProvider, CloudClassicPageOps) {
        let ops = CloudClassicPageOps(backend: backend(machines))
        return (CloudPageProvider(op: CloudAppLinks.ops(classic: ops), feed: CloudAppLinks.feed(classic: ops)), ops)
    }

    /// Lets the observation's main-actor hop run.
    static func settle(until done: () -> Bool) async {
        for _ in 0..<50 where !done() { await Task.yield() }
    }

    /// The red test: the app's own Cloud page provider on the classic link (the default) answers
    /// with no daemon relay at all. Before, it threw `cmux.protocol.transport` (the disconnected
    /// state) because the op went to the Cloud app server.
    @Test func theClassicLinkPageAnswersWithoutTheRelay() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.cloud.configuration.linkSource == .legacy)
        let provider = PageFactory.cloudProvider(cloud: services.cloud, registry: services.machines)
        let answer = try await provider.call("cmux.cloud.auth.status", params: .object([:]), context: Self.page)
        #expect(answer["signedIn"]?.boolValue == services.cloud.isSignedIn)
    }

    @Test func theListIsTheSidebarsMachinesAsPageRecords() async throws {
        let machines = Machines()
        machines.list = [CloudMachine(id: "vm-1", status: .running, displayName: "box"),
                         CloudMachine(id: "vm-2", status: .paused)]
        let (provider, _) = Self.provider(machines)
        let auth = try await provider.call("cmux.cloud.auth.status", params: .object([:]), context: Self.page)
        #expect(auth["signedIn"]?.boolValue == true)
        #expect(auth["team"]?.stringValue == "team-1")
        let list = try await provider.call("cmux.cloud.machine.list", params: .object([:]), context: Self.page)
        let records = list["machines"]?.arrayValue ?? []
        #expect(records.map { $0["id"]?.stringValue } == ["vm-1", "vm-2"])
        #expect(records.map { $0["status"]?.stringValue } == ["running", "paused"])
        #expect(records.first?["name"]?.stringValue == "box")
        #expect(list["revision"]?.intValue == 1)
        #expect(records.first?["revision"]?.stringValue == "1")
    }

    @Test func signedOutReadsAuthAndRefusesTheList() async throws {
        let machines = Machines()
        machines.signedIn = false
        let (provider, _) = Self.provider(machines)
        let auth = try await provider.call("cmux.cloud.auth.status", params: .object([:]), context: Self.page)
        #expect(auth["signedIn"]?.boolValue == false)
        do {
            _ = try await provider.call("cmux.cloud.machine.list", params: .object([:]), context: Self.page)
            Issue.record("a signed-out list answered")
        } catch let error as PageError {
            #expect(error.code == "cmux.cloud.auth_required")
        }
    }

    /// A change the page did not make (a refresh, the CLI, the sidebar) reaches its watch stream.
    @Test func registryChangesReachTheWatchStreamUntilTheLastWatcherLeaves() async throws {
        let machines = Machines()
        machines.list = [CloudMachine(id: "vm-1", status: .running)]
        let (provider, ops) = Self.provider(machines)
        let seen = Seen()
        let subscription = try await provider.subscribe(CloudPageProvider.watchStream, filter: .object([:]), context: Self.page) {
            seen.items.append($0)
        }
        let list = try await provider.call("cmux.cloud.machine.list", params: .object([:]), context: Self.page)
        let listed = try #require(list["revision"]?.intValue)
        #expect(ops.listenerCount == 1)

        machines.list[0].status = .paused
        await Self.settle { !seen.items.isEmpty }
        #expect(seen.items.first?["type"]?.stringValue == "upsert")
        #expect(seen.items.first?["machine"]?["status"]?.stringValue == "paused")
        #expect((seen.items.first?["revision"]?.intValue ?? 0) > listed)

        machines.list.append(CloudMachine(id: "vm-2", status: .provisioning))
        await Self.settle { seen.items.count >= 2 }
        #expect(seen.items.last?["machine"]?["id"]?.stringValue == "vm-2")

        machines.list.removeAll { $0.id == "vm-1" }
        await Self.settle { seen.items.count >= 3 }
        #expect(seen.items.last?["type"]?.stringValue == "removed")
        #expect(seen.items.last?["id"]?.stringValue == "vm-1")

        subscription.cancel()
        #expect(ops.listenerCount == 0)
        let count = seen.items.count
        machines.list.removeAll()
        await Self.settle { false }
        #expect(seen.items.count == count)
    }

    @Test func pauseAndStartRunTheClassicCallsAndAnswerTheRecord() async throws {
        let machines = Machines()
        machines.list = [CloudMachine(id: "vm-1", status: .running)]
        let (provider, _) = Self.provider(machines)
        let paused = try await provider.call("cmux.cloud.machine.pause", params: ["machine": .string("vm-1"), "idempotency_key": .string("k1")],
                                             context: Self.page)
        #expect(paused["machine"]?["status"]?.stringValue == "paused")
        let started = try await provider.call("cmux.cloud.machine.start", params: ["machine": .string("vm-1"), "idempotency_key": .string("k2")],
                                              context: Self.page)
        #expect(started["machine"]?["status"]?.stringValue == "running")
        #expect((started["revision"]?.intValue ?? 0) > (paused["revision"]?.intValue ?? 0))
        #expect(machines.ran == ["pause vm-1", "resume vm-1"])
        do {
            _ = try await provider.call("cmux.cloud.machine.pause", params: ["machine": .string("vm-9")], context: Self.page)
            Issue.record("an unknown machine paused")
        } catch let error as PageError {
            #expect(error.code == "cmux.cloud.not_found")
        }
    }

    @Test func createAndDeleteRunOnlyAsThePerson() async throws {
        let machines = Machines()
        machines.list = [CloudMachine(id: "vm-1", status: .running)]
        let (provider, _) = Self.provider(machines)
        for op in ["cmux.cloud.machine.delete", "cmux.cloud.machine.create"] {
            do {
                _ = try await provider.call(op, params: ["machine": .string("vm-1"), "size": ["memory_mb": .number(8192)]], context: Self.page)
                Issue.record("\(op) ran as a script")
            } catch let error as PageError {
                #expect(error.code == "cmux.cloud.forbidden")
            }
        }
        #expect(machines.ran.isEmpty)
        let created = try await provider.call("cmux.cloud.machine.create",
                                              params: ["name": .string("box"), "size": ["memory_mb": .number(8192)], "idempotency_key": .string("k3")],
                                              context: Self.confirmed)
        #expect(created["machine"]?["id"]?.stringValue == "vm-new")
        #expect(created["machine"]?["status"]?.stringValue == "provisioning")
        let deleted = try await provider.call("cmux.cloud.machine.delete", params: ["machine": .string("vm-1"), "idempotency_key": .string("k4")],
                                              context: Self.confirmed)
        #expect(deleted["deleted"]?.boolValue == true)
        #expect(machines.ran == ["create box 8192 k3", "delete vm-1"])
    }

    @Test func thePlanIsTheListsCapAndOtherOpsAreUnsupported() async throws {
        let machines = Machines()
        let (provider, _) = Self.provider(machines)
        do {
            _ = try await provider.call("cmux.cloud.plan.get", params: .object([:]), context: Self.page)
            Issue.record("a plan answered with no cap")
        } catch let error as PageError {
            #expect(error.code == "cmux.cloud.unsupported")
        }
        machines.limits = CloudMachineLimits(maxActiveVms: 2, activeVmCount: 1, planId: "free")
        let plan = try await provider.call("cmux.cloud.plan.get", params: .object([:]), context: Self.page)
        #expect(plan["plan_id"]?.stringValue == "free")
        #expect(plan["limits"]?["max_active"]?.intValue == 2)
        #expect(plan["usage"]?["active"]?.intValue == 1)
        #expect(plan["limits"]?["memory_options_mb"]?.arrayValue?.compactMap(\.intValue) == [4096, 8192])
        for op in ["cmux.cloud.snapshot.list", "cmux.cloud.fs.list", "cmux.cloud.migration.status"] {
            do {
                _ = try await provider.call(op, params: .object([:]), context: Self.page)
                Issue.record("\(op) answered on the classic link")
            } catch let error as PageError {
                #expect(error.code == "cmux.cloud.unsupported")
            }
        }
    }
}
