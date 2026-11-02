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
        var unavailable: String?
        var user = "user-a"
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
            unavailable: { machines.unavailable },
            machines: { machines.list },
            limits: { machines.limits },
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

    @Test func theListKeepsAnOptimisticPowerChangeUntilItsRecordSettles() async throws {
        let machines = Machines()
        var machine = CloudMachine(id: "vm-1", status: .running)
        machine.pendingChange = .pausing
        machines.list = [machine]
        let (provider, _) = Self.provider(machines)
        let pending = try await provider.call("cmux.cloud.machine.list", params: .object([:]), context: Self.page)
        #expect(pending["machines"]?.arrayValue?.first?["status"]?.stringValue == "pausing")

        machines.list = [CloudMachine(id: "vm-1", status: .paused)]
        let settled = try await provider.call("cmux.cloud.machine.list", params: .object([:]), context: Self.page)
        #expect(settled["machines"]?.arrayValue?.first?["status"]?.stringValue == "paused")
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

        // A page mutation reaches the stream once: the feed sends it, the provider does not announce it again.
        let before = seen.items.count
        _ = try await provider.call("cmux.cloud.machine.pause", params: ["machine": .string("vm-2")], context: Self.page)
        await Self.settle { false }
        #expect(seen.items.count == before + 1)
        #expect(seen.items.last?["machine"]?["status"]?.stringValue == "paused")

        subscription.cancel()
        #expect(ops.listenerCount == 0)
        let count = seen.items.count
        machines.list.removeAll()
        await Self.settle { false }
        #expect(seen.items.count == count)
    }

    /// Dogfood 2026-10-31: the page listed `vm-1304f870…` for machines the sidebar and the CLI name
    /// `kind-aqua-sandpiper`. A record's name is the sidebar's (``CloudMachine/shownName``).
    @Test func aRecordIsNamedAsTheSidebarNamesIt() async throws {
        let machines = Machines()
        machines.list = [CloudMachine(id: "vm-1", status: .running, slug: "kind-aqua-sandpiper"),
                         CloudMachine(id: "vm-2", status: .running, displayName: "fs-lane-1", slug: "tidy-yellow-tern"),
                         CloudMachine(id: "vm-3", status: .paused)]
        let (provider, _) = Self.provider(machines)
        let list = try await provider.call("cmux.cloud.machine.list", params: .object([:]), context: Self.page)
        let records = list["machines"]?.arrayValue ?? []
        #expect(records.map { $0["name"]?.stringValue } == ["kind-aqua-sandpiper", "fs-lane-1", nil])
        #expect(machines.list.map(\.title) == ["kind-aqua-sandpiper", "fs-lane-1", "vm-3"])
    }

    /// Dogfood 2026-10-31: a Cloud page opened while signed out kept its Sign In hero after the
    /// app signed in. The page's account stream sends the current account, then each change.
    @Test func theAccountStreamFollowsTheAppsSignIn() async throws {
        let machines = Machines()
        machines.signedIn = false
        let ops = CloudClassicPageOps(backend: Self.backend(machines))
        let provider = CloudPageProvider(op: CloudAppLinks.ops(classic: ops), feed: CloudAppLinks.feed(classic: ops),
                                         account: { CloudPageProvider.accountValue(signedIn: machines.signedIn, user: machines.user, team: "team-1") })
        let seen = Seen()
        let subscription = try await provider.subscribe(CloudPageProvider.authStream, filter: .object([:]), context: Self.page) {
            seen.items.append($0)
        }
        #expect(seen.items.map { $0["signedIn"]?.boolValue } == [false])
        #expect(seen.items.first?["team"] == .null)

        machines.signedIn = true
        await Self.settle { seen.items.count >= 2 }
        #expect(seen.items.last?["signedIn"]?.boolValue == true)
        #expect(seen.items.last?["team"]?.stringValue == "team-1")
        #expect(seen.items.last?["user"]?.stringValue == "user-a")

        // Another signed-in account (same team shape): still a change the page must see.
        machines.user = "user-b"
        await Self.settle { seen.items.count >= 3 }
        #expect(seen.items.last?["user"]?.stringValue == "user-b")

        machines.signedIn = false
        await Self.settle { seen.items.count >= 4 }
        #expect(seen.items.last?["signedIn"]?.boolValue == false)
        #expect(seen.items.last?["user"] == .null)

        subscription.cancel()
        #expect(provider.accountWatcherCount == 0)
        machines.signedIn = true
        await Self.settle { false }
        #expect(seen.items.count == 4)
    }

    /// A provider given no account (tests, an older wiring) refuses the stream; the page goes on without it.
    @Test func noAccountRefusesTheAccountStream() async throws {
        let (provider, _) = Self.provider(Machines())
        do {
            _ = try await provider.subscribe(CloudPageProvider.authStream, filter: .object([:]), context: Self.page) { _ in }
            Issue.record("the account stream was served with no account")
        } catch let error as PageError {
            #expect(error.code == PageError.unknownOp(CloudPageProvider.authStream).code)
        }
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

    @Test func deleteRunsOnlyAsThePersonAndCreateIsNotServed() async throws {
        let machines = Machines()
        machines.list = [CloudMachine(id: "vm-1", status: .running)]
        let (provider, _) = Self.provider(machines)
        do {
            _ = try await provider.call("cmux.cloud.machine.delete", params: ["machine": .string("vm-1")], context: Self.page)
            Issue.record("delete ran as a script")
        } catch let error as PageError {
            #expect(error.code == "cmux.cloud.forbidden")
        }
        // The page's create is not a confirmed op of the Cloud page, so it never reaches the
        // provider; were it sent, the classic ops serve none.
        for context in [Self.page, Self.confirmed] {
            do {
                _ = try await provider.call("cmux.cloud.machine.create", params: ["size": ["memory_mb": .number(8192)]], context: context)
                Issue.record("create ran on the classic link")
            } catch let error as PageError {
                #expect(error.code == "cmux.cloud.unsupported")
            }
        }
        #expect(machines.ran.isEmpty)
        let deleted = try await provider.call("cmux.cloud.machine.delete", params: ["machine": .string("vm-1"), "idempotency_key": .string("k4")],
                                              context: Self.confirmed)
        #expect(deleted["deleted"]?.boolValue == true)
        #expect(machines.ran == ["delete vm-1"])
    }

    /// Turned off by the organization (or no managed team, a local-only backend): the page reads
    /// the reason, no classic call goes out, and a watching page drops the machines live.
    @Test func unavailableCloudRefusesEveryCallAndListsNoMachine() async throws {
        let machines = Machines()
        machines.list = [CloudMachine(id: "vm-1", status: .running)]
        let (provider, ops) = Self.provider(machines)
        let seen = Seen()
        let watching = try await provider.subscribe(CloudPageProvider.watchStream, filter: .object([:]), context: Self.page) {
            seen.items.append($0)
        }
        _ = try await provider.call("cmux.cloud.machine.list", params: .object([:]), context: Self.page)
        machines.unavailable = "Turned off"
        await Self.settle { !seen.items.isEmpty }
        #expect(seen.items.contains { $0["type"]?.stringValue == "removed" && $0["id"]?.stringValue == "vm-1" })
        let auth = try await provider.call("cmux.cloud.auth.status", params: [:], context: Self.page)
        #expect(auth["signedIn"]?.boolValue == true)
        for (op, context) in [("cmux.cloud.machine.list", Self.page), ("cmux.cloud.machine.pause", Self.page),
                              ("cmux.cloud.machine.rename", Self.page), ("cmux.cloud.machine.delete", Self.confirmed)] {
            do {
                _ = try await provider.call(op, params: ["machine": .string("vm-1"), "name": .string("x")], context: context)
                Issue.record("\(op) ran while Cloud is unavailable")
            } catch let error as PageError {
                #expect(error.code == "cmux.cloud.unavailable")
                #expect(error.message == "Turned off")
            }
        }
        #expect(machines.ran.isEmpty)
        watching.cancel()
        #expect(ops.listenerCount == 0)
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
        machines.limits = try JSONDecoder().decode(CloudMachineLimits.self, from: Data(#"{"maxActiveVms":2,"activeVmCount":1,"planId":"free","memoryOptionsMb":[8192,4096],"lockedMemoryOptionsMb":[32768,16384]}"#.utf8))
        let plan = try await provider.call("cmux.cloud.plan.get", params: .object([:]), context: Self.page)
        #expect(plan["plan_id"]?.stringValue == "free")
        #expect(plan["limits"]?["max_active"]?.intValue == 2)
        #expect(plan["usage"]?["active"]?.intValue == 1)
        #expect(plan["limits"]?["memory_options_mb"]?.arrayValue?.compactMap(\.intValue) == [4096, 8192])
        #expect(plan["limits"]?["locked_memory_options_mb"]?.arrayValue?.compactMap(\.intValue) == [16384, 32768])
        // The same provider reads updated entitlements, rather than keeping its initial ladder.
        machines.limits = try JSONDecoder().decode(CloudMachineLimits.self, from: Data(#"{"maxActiveVms":1,"activeVmCount":0,"planId":"go","memoryOptionsMb":[4096],"lockedMemoryOptionsMb":[8192,16384]}"#.utf8))
        let go = try await provider.call("cmux.cloud.plan.get", params: .object([:]), context: Self.page)
        #expect(go["limits"]?["memory_options_mb"]?.arrayValue?.compactMap(\.intValue) == [4096])
        #expect(go["limits"]?["locked_memory_options_mb"]?.arrayValue?.compactMap(\.intValue) == [8192, 16384])
        // Older servers provide no size entitlement: do not invent allowed sizes.
        machines.limits = CloudMachineLimits(maxActiveVms: 1, activeVmCount: 0)
        let old = try await provider.call("cmux.cloud.plan.get", params: .object([:]), context: Self.page)
        #expect(old["limits"]?["memory_options_mb"]?.arrayValue?.isEmpty == true)
        #expect(old["limits"]?["locked_memory_options_mb"]?.arrayValue?.isEmpty == true)
        for op in ["cmux.cloud.snapshot.list", "cmux.cloud.fs.list", "cmux.cloud.migration.status"] {
            do {
                _ = try await provider.call(op, params: .object([:]), context: Self.page)
                Issue.record("\(op) answered on the classic link")
            } catch let error as PageError {
                #expect(error.code == "cmux.cloud.unsupported")
            }
        }
    }

    /// A classic call's error keeps the codes the page acts on: a plan refusal with its plan, a
    /// machine already gone, a lapsed sign-in.
    @Test func classicErrorsKeepThePagesCodes() {
        let plan = CloudClassicPageOps.Backend.classicRefusal(CloudAPIError.planRequired(message: "Needs Max", upgradeURL: nil, plan: "max"))
        #expect(plan.code == "cmux.cloud.plan_required")
        #expect(plan.details["plan"] == "max")
        #expect(CloudClassicPageOps.Backend.classicRefusal(CloudAPIError.http(status: 404, code: nil, message: "gone")).code == "cmux.cloud.not_found")
        #expect(CloudClassicPageOps.Backend.classicRefusal(CloudAPIError.http(status: 409, code: "vm_not_found", message: nil)).code == "cmux.cloud.not_found")
        #expect(CloudClassicPageOps.Backend.classicRefusal(CloudAPIError.notSignedIn).code == "cmux.cloud.auth_required")
        #expect(CloudClassicPageOps.Backend.classicRefusal(CloudAPIError.http(status: 500, code: nil, message: "boom")).code == "cmux.cloud.failed")
    }
}
