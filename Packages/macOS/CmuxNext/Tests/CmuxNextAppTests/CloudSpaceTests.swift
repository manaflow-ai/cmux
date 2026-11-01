import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
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

    static func isMac(_ creation: MachineRegistry.SpaceCreation) -> Bool { if case .mac = creation { true } else { false } }
    static func isUnresolved(_ creation: MachineRegistry.SpaceCreation) -> Bool { if case .unresolved = creation { true } else { false } }

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
        #expect(services.machines.creation(in: Self.cloudSpace).daemon === machine.daemon,
                "a Cloud space's new workspace must go to its machine, not the Mac")
        #expect(services.machines.cloudSession(of: machine.daemon) === machine)
        #expect(services.windows.spaceCreation(WorkspaceSpawn(profile: Self.cloudSpace), into: nil).daemon === machine.daemon)
    }

    @Test func aPlainSpaceCreatesOnTheMacAndAnUnknownMachineIsRefusedNotMadeOnTheMac() {
        let services = Self.services()
        _ = Self.cloudMachine(services, id: "vm-space")
        #expect(Self.isMac(services.machines.creation(in: Self.plainSpace)))
        #expect(Self.isMac(services.machines.creation(in: .defaultProfile)))
        #expect(Self.isUnresolved(services.machines.creation(in: Self.goneSpace)),
                "a space whose machine is not listed must refuse, never pin a Mac workspace into it")
        #expect(services.machines.cloudSession(of: services.machines.local) == nil)
    }

    /// Finder's New Workspace Here, `cmux open <dir>`, a resumed or imported chat: what they open is on this Mac.
    @Test func aCreateCarryingSomethingOfThisMacStaysOnTheMacInACloudSpace() {
        let services = Self.services()
        _ = Self.cloudMachine(services, id: "vm-space")
        var folder = WorkspaceSpawn(opening: "/Users/someone/project")
        folder.profile = Self.cloudSpace
        #expect(Self.isMac(services.windows.spaceCreation(folder, into: nil)))
        var command = WorkspaceSpawn(profile: Self.cloudSpace)
        command.command = "make"
        #expect(Self.isMac(services.windows.spaceCreation(command, into: nil)))
        var session = WorkspaceSpawn(profile: Self.cloudSpace)
        session.firstSession = "claude-session-1"
        #expect(Self.isMac(services.windows.spaceCreation(session, into: nil)))
    }

    /// A space whose machine is not listed (the machine list has not come, the account signed out) has nothing to
    /// show and nowhere to create: the switch is refused and the window keeps its space, never an empty one.
    @Test func switchingIntoASpaceWhoseMachineIsUnknownKeepsTheWindowWhereItIs() {
        let services = Self.services()
        let state = services.windows.state(for: "w-cloud-space")
        #expect(state.profileID == .defaultProfile)
        services.windows.switchProfile(Self.goneSpace, in: state)
        #expect(state.profileID == .defaultProfile, "the window entered a space it can show nothing in")
    }

    /// A Cloud space whose machine failed to load falls back without another wait: its previous space here is
    /// another Cloud space with nothing shown, so the window goes to `default`, never back and forth between them.
    @Test func aFailedCloudSpaceFallsBackToDefaultNotIntoAnotherWait() {
        let services = Self.services()
        _ = Self.cloudMachine(services, id: "vm-space")
        let state = services.windows.state(for: "w-cloud-fallback")
        state.enterProfile(Self.goneSpace)
        services.windows.fallBack(preferring: Self.cloudSpace, in: state)
        #expect(state.profileID == .defaultProfile, "the window went into another Cloud space's wait: \(state.profileID)")
    }

    /// A Cloud space's first New Tab page is the machine's: its folders, never this Mac's home or projects, and
    /// not warmed in this Mac's acpmux (its chats start on the machine).
    @Test func aCloudWorkspacesFirstPageShowsTheMachineNotThisMac() {
        let services = Self.services()
        let machine = Self.cloudMachine(services, id: "vm-space")
        let context = NewTabPageMachine(services, selected: nil, machine: machine.daemon)
        #expect(context.home == nil, "a Cloud page offered this Mac's home")
        #expect(context.remoteFolders != nil, "a Cloud page listed this Mac's projects")
        #expect(NewTabPageMachine(services, selected: nil).home == NSHomeDirectory(), "this Mac's page lost its home")
    }

    /// A machine whose daemon cannot start chats there (an older cmux-tui, not connected) keeps the terminal.
    @Test func aCloudMachineThatCannotStartChatsOpensATerminal() {
        let services = Self.services()
        let machine = Self.cloudMachine(services, id: "vm-space")
        #expect(!services.agentTabs.opensRemotePage(machine.daemon))
        #expect(!services.agentTabs.opensRemotePage(services.machines.local))
    }

    @Test func aBrowserProfileCreateStaysOnTheMac() {
        let services = Self.services()
        _ = Self.cloudMachine(services, id: "vm-space")
        var browser = WorkspaceSpawn(profile: Self.cloudSpace)
        browser.browserProfile = "work"
        #expect(Self.isMac(services.windows.spaceCreation(browser, into: nil)))
    }

    @Test func theSpaceFollowsTheMachineSoItsWorkspacesLeaveTheDefaultSpace() {
        let services = Self.services()
        #expect(services.machines.local.store.personal.follows[Self.cloudSpace] == ["s-vm"])
        let membership = RoomMembership(follows: services.machines.local.store.personal.follows)
        let onTheMachine = RoomMembership.Workspace(session: "s-vm", key: "w1")
        #expect(membership.rooms(of: onTheMachine) == [Self.cloudSpace])
        #expect(membership.rooms(of: .init(session: "s-local", key: "w2")) == [.defaultProfile])
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

    private struct Commands: DaemonRequest {
        typealias Response = CmuxNextDaemon.JSONValue
        static let command = "test-commands"
    }

    /// This Mac's daemon, faked: it answers every command and lists the commands it was sent.
    private static let localDaemon = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    commands = []
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        commands.append(command)
        if command == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'cloud-space-test', 'capabilities': ['profiles-v1']}
        elif command == 'test-commands':
            data = {'commands': commands}
        elif command in ('list-workspaces',):
            data = {'workspaces': []}
        elif command == 'create-workspace':
            data = {'workspace': 5, 'key': frame.get('key'), 'workspace_revision': 1, 'replayed': False}
        else:
            data = {}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    /// A script's create that names a machine this app cannot resolve (unknown, or Cloud off) is refused: it never
    /// falls back to this Mac's connected daemon, so a command meant for that machine never runs on the person's
    /// Mac (fail closed, REVIEW.md 5).
    @Test(.timeLimit(.minutes(1))) func aScriptsCreateOnAnUnknownMachineIsRefusedNotMadeOnTheMac() async throws {
        let services = Self.services()
        AppActions.bind(services) // the real New Workspace handler, as the app binds it
        services.windows.ordersWindowsIn = false
        let local = services.machines.local
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-cloud-space-\(UUID().uuidString).sock",
                            bridge: .fakePython(["-c", Self.localDaemon])),
            configuration: .init(requiredCapabilities: [], requestTimeout: .seconds(1), spawnTimeout: .seconds(1),
                                 terminalEnvironment: nil))
        let identity = try await connection.start()
        local.start(first: { .success((connection, identity)) }, makeConnection: { connection })
        defer { local.shutdownConnection() }
        await local.firstConnection()
        try #require(local.connection != nil, "the test needs this Mac's daemon connected")

        let invocation = ActionInvocation(arguments: ["machine": .string("vm-unknown"), "command": .string("echo hi")],
                                          origin: .script)
        // The handler's own work, awaited to its end: no yield count decides the result.
        var performed = false
        let work = services.registry.capturingWork { performed = services.registry.perform("newTab", invocation: invocation) }
        try #require(performed, "New Workspace did not run")
        try #require(work.count == 1, "the create reported \(work.count) works")
        var failures: [ActionWorkFailure?] = []
        for task in work { failures.append(await task.value) }
        let sent = try await connection.request(Commands())
        await connection.closeAndWait()
        let commands = sent["commands"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(failures.map { $0?.message } == [WorkspaceVerbStrings.machineNotConnected], "the create was not refused: \(failures)")
        #expect(!commands.contains("create-workspace"), "a create for an unknown machine was made on this Mac: \(commands)")
    }

    @Test func newCloudSpaceIsOnEverySurface() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "space.newCloud" })
        #expect(descriptor.cliName == "space new-cloud")
        #expect(descriptor.targets == [.machine])
    }
}
