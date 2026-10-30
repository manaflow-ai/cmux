import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A Cloud space is one Cloud machine (RoomHandlers.bindCloudSpace): it follows the machine's session and New Workspace in
/// it creates on that machine (`MachineRegistry.creationDaemon`), also while the machine is paused and this run has
/// no daemon identity for it yet, through the home registry's record of the session's transport. A space without a
/// default session, or whose machine is gone, creates on the Mac as before.
@MainActor @Suite(.serialized)
struct CloudSpaceTests {
    static let cloudSpace = ProfileID(rawValue: "p-cloud")
    static let plainSpace = ProfileID(rawValue: "p-plain")
    static let goneSpace = ProfileID(rawValue: "p-gone")

    /// This Mac's home daemon with three spaces: one on Cloud machine `vm-space` (session `s-vm`), one plain, and
    /// one on session `s-gone`, whose machine is no longer in the registry.
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        var tree = DaemonTree(registryID: "s-local")
        tree.personal = PersonalState(sessions: [
            SessionRecord(id: "s-local", transport: .object(["kind": .string("local")]), migrated: true),
            SessionRecord(id: "s-vm", transport: .object(["kind": .string("cloud"), "machine": .string("vm-space")]), migrated: true),
            SessionRecord(id: "s-gone", transport: .object(["kind": .string("cloud"), "machine": .string("vm-gone")]), migrated: true),
        ], profiles: [
            ProfileSnapshot(id: .defaultProfile, name: "Default"),
            ProfileSnapshot(id: cloudSpace, name: "VM", icon: "cloud", index: 1, defaultSessionID: "s-vm", follows: ["s-vm"]),
            ProfileSnapshot(id: plainSpace, name: "Work", index: 2),
            ProfileSnapshot(id: goneSpace, name: "Old VM", index: 3, defaultSessionID: "s-gone", follows: ["s-gone"]),
        ])
        services.machines.local.store.apply(snapshot: tree)
        return services
    }

    /// A Cloud machine `id` this run has not connected (paused, or its link has not answered).
    static func cloudMachine(_ services: AppServices, id: String) -> CloudMachineSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-cloud-space-\(UUID().uuidString.prefix(8))")
        let paths = CloudPaths(root: root), binary = URL(fileURLWithPath: "/usr/bin/false"), api = services.cloud.api
        let hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: "cn-cloud-space-test")
        let link = CloudMachineLink(machineID: id, api: api, hub: hub, paths: paths, binary: binary, deviceName: "cn-cloud-space-test")
        let session = CloudMachineSession(machine: CloudMachine(id: id, displayName: "Space VM"), link: link, mainWork: services.mainWork)
        services.machines.add(session)
        return session
    }

    @Test func aCloudSpaceCreatesOnItsMachineEvenBeforeItConnects() throws {
        let services = Self.services()
        let machine = Self.cloudMachine(services, id: "vm-space")
        #expect(machine.daemon.identity == nil, "the machine has not connected in this run")
        let daemon = try #require(services.machines.creationDaemon(for: Self.cloudSpace), "a Cloud space resolved to no machine")
        #expect(daemon === machine.daemon, "a Cloud space's new workspace must go to its machine, not the Mac")
        #expect(services.machines.cloudSession(of: daemon) === machine)
    }

    @Test func aSpaceWithoutADefaultSessionOrWithItsMachineGoneCreatesOnTheMac() {
        let services = Self.services()
        _ = Self.cloudMachine(services, id: "vm-space")
        #expect(services.machines.creationDaemon(for: Self.plainSpace) == nil)
        #expect(services.machines.creationDaemon(for: .defaultProfile) == nil)
        #expect(services.machines.creationDaemon(for: Self.goneSpace) == nil, "a deleted machine's space falls back to the Mac")
        #expect(services.machines.cloudSession(of: services.machines.local) == nil)
    }

    @Test func theSpaceFollowsTheMachineSoItsWorkspacesLeaveTheDefaultSpace() {
        let services = Self.services()
        #expect(services.machines.local.store.personal.follows[Self.cloudSpace] == ["s-vm"])
        let membership = RoomMembership(follows: services.machines.local.store.personal.follows)
        let onTheMachine = RoomMembership.Workspace(session: "s-vm", key: "w1")
        #expect(membership.rooms(of: onTheMachine) == [Self.cloudSpace])
        #expect(membership.rooms(of: .init(session: "s-local", key: "w2")) == [.defaultProfile])
    }

    @Test func onlyACloudTransportNamesAMachine() {
        #expect(MachineRegistry.cloudMachineID(of: SessionRecord(id: "a", transport: .object(["kind": .string("cloud"), "machine": .string("vm-1")]))) == "vm-1")
        #expect(MachineRegistry.cloudMachineID(of: SessionRecord(id: "a", transport: .object(["kind": .string("local")]))) == nil)
        #expect(MachineRegistry.cloudMachineID(of: SessionRecord(id: "a", transport: .object(["kind": .string("cloud"), "machine": .string("")]))) == nil)
        #expect(MachineRegistry.cloudMachineID(of: SessionRecord(id: "a")) == nil)
    }

    /// `create-profile` makes the space, its follow and its default session in one command (the daemon reads
    /// `default_session_id` and `follows`), so it never shows for a moment as an empty Mac space.
    @Test func createProfileSendsItsSessionAndFollowsInOneCommand() throws {
        let request = CreateProfileRequest(name: "VM", profile: Self.cloudSpace, icon: "cloud", defaultSessionID: "s-vm", follows: ["s-vm"])
        let data = try WireCoding.encoder().encode(request)
        let sent = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(sent["default_session_id"] as? String == "s-vm")
        #expect(sent["follows"] as? [String] == ["s-vm"])
        let plain = try #require(JSONSerialization.jsonObject(with: try WireCoding.encoder().encode(CreateProfileRequest(name: "Work"))) as? [String: Any])
        #expect(plain["default_session_id"] == nil && plain["follows"] == nil, "a plain space sends neither")
    }

    @Test func newCloudSpaceIsOnEverySurface() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "space.newCloud" })
        #expect(descriptor.cliName == "space new-cloud")
        #expect(descriptor.targets == [.machine])
    }
}
