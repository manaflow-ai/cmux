import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// `cmux cloud list-machines` from the CLI, MCP or a script answers the app's
/// own Cloud machine list (the sidebar's) as `action.run`'s `result`, so an
/// agent can check whether its machine already exists before it creates one.
/// A paused machine reads `paused`: the progress stage calls it `failed`.
@MainActor @Suite(.serialized)
struct CloudListMachinesTests {
    /// App services with every action bound, as the app binds them at launch.
    static func services() -> AppServices {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        return services
    }

    /// The bound action's result for a run from `origin`, or nil when it tracked none.
    static func run(_ services: AppServices, origin: ActionOrigin) async throws -> [String: ActionResultValue]? {
        let action = try #require(services.registry.action(for: "cloudListMachines"), "cloud list-machines is not bound")
        let invoke = try #require(action.invoke)
        let run = services.registry.capturingRun { invoke(ActionInvocation(origin: origin)) }
        guard let task = run.results.first else { return nil }
        guard case .success(let fields) = await task.value else {
            Issue.record("the list failed")
            return nil
        }
        return fields
    }

    static func members(_ value: ActionResultValue?) -> [String: ActionResultValue]? {
        guard case .object(let members)? = value else { return nil }
        return members
    }

    /// The CLI, MCP and a script all get the list as JSON (arrays and objects, not a string).
    @Test(arguments: [ActionOrigin.cli, .mcp, .script])
    func aNonPersonRunGetsTheListAsJSON(origin: ActionOrigin) async throws {
        let services = Self.services()
        let fields = try #require(try await Self.run(services, origin: origin), "a \(origin) run tracked no result")
        guard case .bool(_)? = fields["loaded"], case .array(_)? = fields["machines"], case .int(_)? = fields["count"] else {
            Issue.record("not the list's shape: \(fields)")
            return
        }
        #expect(Self.members(fields["account"])?["signed_in"] != nil)
    }

    /// Each machine of a loaded list, with the target the other verbs take; a paused one reads
    /// `paused` (its progress stage says failed).
    @Test func aLoadedListGivesEachMachineAndItsStatus() throws {
        let services = Self.services()
        let running = MachineIconTests.cloudMachine(services, id: "vm-list-run-\(UUID().uuidString.prefix(8))")
        let paused = MachineIconTests.cloudMachine(services, id: "vm-list-pause-\(UUID().uuidString.prefix(8))")
        paused.machine.status = .paused
        paused.machine.displayName = "Paused VM"
        paused.machine.createdAt = Date(timeIntervalSince1970: 1_760_000_000)

        let fields = CloudHandlers.machineListFields(AppActionContext(services: services), loaded: true)
        #expect(fields["loaded"] == .bool(true))
        guard case .array(let rows)? = fields["machines"] else {
            Issue.record("machines is not a list: \(String(describing: fields["machines"]))")
            return
        }
        #expect(fields["count"] == .int(2))
        var byID: [String: [String: ActionResultValue]] = [:]
        for row in rows.compactMap({ Self.members($0) }) {
            if case .string(let id)? = row["machine_id"] { byID[id] = row }
        }
        let pausedRow = try #require(byID[paused.machineID])
        #expect(pausedRow["status"] == .string("paused"), "a paused machine is not failed")
        #expect(pausedRow["target"] == .string("machine:\(paused.machineID)"))
        #expect(pausedRow["title"] == .string("Paused VM"))
        #expect(pausedRow["owner"] == .string("personal"))
        #expect(pausedRow["created_at"] == .string("2025-10-09T08:53:20Z"))

        let runningRow = try #require(byID[running.machineID])
        #expect(runningRow["status"] == .string("running"))
        #expect(runningRow["created_at"] == .null)

        let account = try #require(Self.members(fields["account"]))
        #expect(account["signed_in"] == .bool(false))
        // The store keeps no plan limits; a machine count is no entitlement.
        #expect(account["limits"] == nil)
    }

    /// Before the store's first load (a relaunch, or signed out) its list says nothing about
    /// which machines exist: the answer says `loaded: false` with no machines, so a setup
    /// script never reads "not loaded yet" as "no machines" and creates a second one.
    @Test func aListThatHasNotLoadedSaysSo() async throws {
        let services = Self.services()
        // A session the store holds before any list came back (a create still on its way).
        _ = MachineIconTests.cloudMachine(services, id: "vm-list-early-\(UUID().uuidString.prefix(8))")
        #expect(!services.cloud.hasLoadedMachines && !services.cloud.hasLoadedCurrentMachines)

        let fields = try #require(try await Self.run(services, origin: .cli), "a CLI run tracked no result")
        #expect(fields["loaded"] == .bool(false))
        #expect(fields["machines"] == .array([]))
        #expect(fields["count"] == .int(0))
        #expect(Self.members(fields["account"])?["signed_in"] == .bool(false))
    }

    /// A person's palette run shows the Cloud sidebar instead; it leaves no result to capture.
    @Test func aPersonsRunAnswersNoResult() async throws {
        let services = Self.services()
        _ = MachineIconTests.cloudMachine(services, id: "vm-list-user-\(UUID().uuidString.prefix(8))")
        let fields = try await Self.run(services, origin: .user)
        #expect(fields == nil)
    }
}
