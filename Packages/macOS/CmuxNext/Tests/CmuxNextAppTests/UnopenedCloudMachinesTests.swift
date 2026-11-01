import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-10-29, on agents' Cloud machines in his sidebar: "why is there all this weird stuff at
/// the bottom of the sidebar". Every Cloud machine of the account connects, and a machine starts
/// with a workspace from its image; reconcile gave each such workspace to the most recent window,
/// so every lane-pool and test VM showed a row. A Cloud machine's workspaces now join a window only
/// once the person opened the machine here (one of its workspaces is in a window or claimed).
@MainActor @Suite(.serialized, .closesItsWindows)
struct UnopenedCloudMachinesTests {
    @Test func aMachineWithNoWorkspaceInAWindowHoldsAllOfItsWorkspaces() {
        let opened: Set<String> = ["ws-mine"]
        let held = WindowManager.unopenedCloudWorkspaces([["ws-agent-1", "ws-agent-2"], ["ws-mine", "ws-mine-new"], []]) { opened.contains($0) }
        #expect(held == ["ws-agent-1", "ws-agent-2"])
    }

    @Test func anAgentsFreshMachineStaysOutOfEveryWindow() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-agent", workspaces: ["ws-image-default"])

        services.windows.reconcileMembership()

        #expect(services.windows.registry.value.owner(of: "ws-image-default") == nil,
                "the image's own workspace of a machine nobody opened here joined a window")
        #expect(services.windows.registry.value.windows.isEmpty, "no window opens for it")
    }

    @Test func aMachineThePersonOpenedTakesItsNewWorkspacesIn() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-mine", workspaces: ["ws-opened", "ws-made-later"])
        _ = services.windows.registry.apply { $0.openWindow(id: "w-person", workspaceIDs: ["ws-opened"]) }

        services.windows.reconcileMembership()

        #expect(services.windows.registry.value.owner(of: "ws-made-later") == "w-person",
                "a machine with a workspace in a window takes new ones in, as before")
    }

    /// A VM made from another's snapshot keeps its workspace keys: the copy in a window on the
    /// first machine does not open the second one.
    @Test func aWorkspaceKeySharedWithAnOpenedMachineDoesNotOpenAnother() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-mine", workspaces: ["ws-shared"])
        Self.machine(services, id: "vm-agent-copy", workspaces: ["ws-shared", "ws-agent-own"])
        _ = services.windows.registry.apply { $0.openWindow(id: "w-person", workspaceIDs: ["ws-shared"]) }

        services.windows.reconcileMembership()

        #expect(services.windows.registry.value.owner(of: "ws-agent-own") == nil)
        #expect(services.windows.registry.value.owner(of: "ws-shared") == "w-person")
    }

    /// An ephemeral workspace on a machine nobody opened here opens no incognito window, and is
    /// not the person opening that machine: its other workspaces stay out too.
    @Test func anUnopenedMachinesEphemeralWorkspaceOpensNoWindow() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        let session = Self.machine(services, id: "vm-agent", workspaces: ["ws-ephemeral", "ws-image-default"])
        try #require(session.daemon.store.workspace(id: "ws-ephemeral")).applyState(ephemeral: true, status: nil, screenGroups: nil)

        services.windows.reconcileMembership()

        #expect(services.windows.registry.value.owner(of: "ws-ephemeral") == nil)
        #expect(services.windows.registry.value.owner(of: "ws-image-default") == nil)
        #expect(services.windows.registry.value.windows.isEmpty && services.windows.registry.value.incognito.isEmpty,
                "an agent's ephemeral workspace opened an incognito window")
    }

    /// `cmux cloud new-machine` from a lane-pool tool or an agent, without focus: the machine's
    /// first workspace is not filed into a window; the person's own create still shows it.
    @Test func aMachineAnAgentMadeIsNotFiledButThePersonsIs() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-made", workspaces: ["ws-first"])
        let context = AppActionContext(services: services)
        let creation = services.cloud.creations.begin(window: nil)

        CloudHandlers.creationFlow(context).show("ws-first", creation)
        #expect(services.windows.registry.value.owner(of: "ws-first") == nil, "an agent's create filed its workspace into a window")

        CloudHandlers.creationFlow(context, startedByPerson: true).show("ws-first", creation)
        #expect(services.windows.registry.value.owner(of: "ws-first") != nil, "the person's own create shows its workspace")
    }

    /// `cmux cloud new-machine --focus` with no window open: the run asked for focus, so its first
    /// workspace still opens in a window (review finding).
    @Test func aCreateWithFocusStillShowsItsWorkspaceWithNoWindowOpen() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-focused", workspaces: ["ws-first"])
        let creation = services.cloud.creations.begin(window: nil)

        CloudHandlers.creationFlow(AppActionContext(services: services), reveals: true).show("ws-first", creation)
        #expect(services.windows.registry.value.owner(of: "ws-first") != nil, "a create run with --focus left its workspace in no window")
    }

    /// Review finding: opening a machine (reveal, as Open Machine's show does with no window
    /// open) brought in only the workspace it showed; its other loaded workspaces stayed unowned
    /// and out of the sidebar, since a claim re-runs no reconcile.
    @Test func openingAMachineBringsInItsOtherWorkspaces() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-two", workspaces: ["ws-shown", "ws-other"])
        services.windows.reconcileMembership()
        try #require(services.windows.registry.value.owner(of: "ws-other") == nil)

        services.windows.reveal(workspaceID: "ws-shown")

        let owner = try #require(services.windows.registry.value.owner(of: "ws-shown"))
        #expect(services.windows.registry.value.owner(of: "ws-other") == owner, "the machine's other workspace stayed out of its window")
    }

    /// Review finding: opening a machine whose workspace is ephemeral put it in a normal window
    /// (persisted, never discarded); it goes to an incognito window, as an ephemeral one always did.
    @Test func openingAMachinesEphemeralWorkspaceGivesItAnIncognitoWindow() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        let session = Self.machine(services, id: "vm-eph", workspaces: ["ws-eph"])
        try #require(session.daemon.store.workspace(id: "ws-eph")).applyState(ephemeral: true, status: nil, screenGroups: nil)
        services.windows.reconcileMembership()

        services.windows.reveal(workspaceID: "ws-eph")

        let owner = try #require(services.windows.registry.value.owner(of: "ws-eph"))
        #expect(services.windows.registry.value.isIncognito(owner), "an ephemeral workspace joined a normal window")
    }

    /// Review finding: Open Machine with no window open shows through `CloudHandlers.show`, which
    /// opens a window directly (not through reveal): the machine's other workspaces come in there too.
    @Test func openMachineWithNoWindowBringsInItsOtherWorkspaces() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-open", workspaces: ["ws-first", "ws-second"])
        services.windows.reconcileMembership()
        try #require(services.windows.active == nil)

        CloudHandlers.show("ws-first", AppActionContext(services: services))

        let owner = try #require(services.windows.registry.value.owner(of: "ws-first"))
        #expect(services.windows.registry.value.owner(of: "ws-second") == owner)
    }

    /// Review finding: showing an unopened machine's ephemeral workspace from a normal window
    /// opens its incognito window, and that window is the one that shows it, not the normal one.
    @Test func showingAnEphemeralWorkspaceFromANormalWindowShowsItsIncognitoWindow() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-normal", workspaces: ["ws-normal"])
        let session = Self.machine(services, id: "vm-eph2", workspaces: ["ws-eph2"])
        try #require(session.daemon.store.workspace(id: "ws-eph2")).applyState(ephemeral: true, status: nil, screenGroups: nil)
        services.windows.reconcileMembership()
        let normal = try #require(services.windows.reveal(workspaceID: "ws-normal")?.state)

        services.windows.show(workspaceID: "ws-eph2", in: normal)

        let owner = try #require(services.windows.registry.value.owner(of: "ws-eph2"))
        #expect(owner != normal.id && services.windows.registry.value.isIncognito(owner))
        #expect(services.windows.controller(for: owner)?.state.workspaceID == "ws-eph2", "the incognito window does not show it")
    }

    /// Review finding: a machine opened through its ephemeral workspace (an incognito window) does not
    /// file its normal workspaces into that incognito window, where closing it would discard them.
    @Test func aMachineOpenedThroughItsEphemeralWorkspaceKeepsItsNormalOnesOutOfIncognito() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        let session = Self.machine(services, id: "vm-mixed", workspaces: ["ws-mixed-eph", "ws-mixed-normal"])
        try #require(session.daemon.store.workspace(id: "ws-mixed-eph")).applyState(ephemeral: true, status: nil, screenGroups: nil)
        services.windows.reconcileMembership()

        services.windows.reveal(workspaceID: "ws-mixed-eph")

        let registry = services.windows.registry.value
        let ephemeral = try #require(registry.owner(of: "ws-mixed-eph"))
        let normal = try #require(registry.owner(of: "ws-mixed-normal"), "the machine's normal workspace stayed out")
        #expect(registry.isIncognito(ephemeral) && !registry.isIncognito(normal))
    }

    /// Review finding: a held normal workspace shown from an incognito window goes to a normal
    /// window; in the incognito one, closing it would discard it.
    @Test func aNormalWorkspaceShownFromAnIncognitoWindowGoesToANormalWindow() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        let session = Self.machine(services, id: "vm-inc", workspaces: ["ws-inc-eph"])
        try #require(session.daemon.store.workspace(id: "ws-inc-eph")).applyState(ephemeral: true, status: nil, screenGroups: nil)
        Self.machine(services, id: "vm-plain", workspaces: ["ws-plain"])
        services.windows.reconcileMembership()
        let incognito = try #require(services.windows.reveal(workspaceID: "ws-inc-eph")?.state)
        try #require(services.windows.registry.value.isIncognito(incognito.id))

        services.windows.show(workspaceID: "ws-plain", in: incognito)

        let owner = try #require(services.windows.registry.value.owner(of: "ws-plain"))
        #expect(!services.windows.registry.value.isIncognito(owner), "a normal workspace joined an incognito window")
    }

    /// Review finding: a batch that opens one window with a held normal and a held ephemeral
    /// workspace (Open Space in New Window) gives each a window of its kind.
    @Test func aMixedBatchGivesEachHeldWorkspaceAWindowOfItsKind() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        let session = Self.machine(services, id: "vm-batch", workspaces: ["ws-batch-normal", "ws-batch-eph"])
        try #require(session.daemon.store.workspace(id: "ws-batch-eph")).applyState(ephemeral: true, status: nil, screenGroups: nil)
        services.windows.reconcileMembership()

        services.windows.openWindow(workspaces: ["ws-batch-normal", "ws-batch-eph"])

        let registry = services.windows.registry.value
        let normal = try #require(registry.owner(of: "ws-batch-normal"))
        let ephemeral = try #require(registry.owner(of: "ws-batch-eph"))
        #expect(!registry.isIncognito(normal) && registry.isIncognito(ephemeral))
    }

    /// Review finding: opening a cloned machine files only its own workspaces, never a key it
    /// shares with another unopened machine (that key resolves to the other machine).
    @Test func openingACloneFilesNoWorkspaceOfAnotherMachine() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-a", workspaces: ["ws-cloned", "ws-a-only"])
        Self.machine(services, id: "vm-b", workspaces: ["ws-b-only", "ws-cloned"])
        services.windows.reconcileMembership()

        services.windows.reveal(workspaceID: "ws-b-only")

        #expect(services.windows.registry.value.owner(of: "ws-a-only") == nil, "opening the clone opened the other machine")
    }

    /// Review finding: a batch whose second workspace is a held machine's files that machine's
    /// other workspaces too, not only the first workspace's machine.
    @Test func aBatchOpensEveryHeldMachineItCarries() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        Self.machine(services, id: "vm-one", workspaces: ["ws-one", "ws-one-more"])
        Self.machine(services, id: "vm-two-b", workspaces: ["ws-two", "ws-two-more"])
        services.windows.reconcileMembership()

        let window = try #require(services.windows.openWindow(workspaces: ["ws-one", "ws-two"])?.state.id)

        #expect(services.windows.registry.value.owner(of: "ws-two-more") == window, "the second machine's other workspace stayed out")
    }

    /// Issue #28609: an agent's or the CLI's create on a machine nobody opened (no focus, so its claim
    /// on the active window is quiet) is not the person opening that machine: neither the new
    /// workspace nor the image's own joins the window.
    @Test func aCreateWithoutFocusOpensNoMachine() throws {
        let services = Self.services()
        defer { Self.closeWindows(services) }
        let session = Self.machine(services, id: "vm-cli", workspaces: ["ws-cli-image"])
        _ = services.windows.registry.apply { $0.openWindow(id: "w-person", workspaceIDs: ["ws-person"]) }
        services.windows.reconcileMembership()

        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            services.windows.claimNew(workspaceID: "ws-cli-made", window: "w-person")
        }
        session.daemon.store.apply(snapshot: DaemonTree(registryID: "s-vm-cli", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-cli-image"), name: "workspace-1"),
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "ws-cli-made"), name: "workspace-2"),
        ]))
        services.windows.reconcileMembership()

        #expect(services.windows.registry.value.owner(of: "ws-cli-made") == nil, "a create without focus put its workspace in the window")
        #expect(services.windows.registry.value.owner(of: "ws-cli-image") == nil, "a create without focus opened the machine")
    }

    // MARK: Fixtures

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.machines.local.store.apply(snapshot: DaemonTree(registryID: "s-local"))
        return services
    }

    /// A running Cloud machine whose tree lists `workspaces` (keys), loaded.
    @discardableResult
    static func machine(_ services: AppServices, id: String, workspaces: [String]) -> CloudMachineSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-unopened-\(UUID().uuidString.prefix(8))")
        let paths = CloudPaths(root: root), binary = URL(fileURLWithPath: "/usr/bin/false"), api = services.cloud.api
        let hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: "cn-unopened-test")
        let link = CloudMachineLink(machineID: id, api: api, hub: hub, paths: paths, binary: binary, deviceName: "cn-unopened-test")
        let session = CloudMachineSession(machine: CloudMachine(id: id, status: .running, displayName: id), link: link, mainWork: services.mainWork)
        services.machines.add(session)
        session.daemon.store.apply(snapshot: DaemonTree(registryID: "s-\(id)", workspaces: workspaces.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: "workspace-\(index + 1)")
        }))
        return session
    }

    static func closeWindows(_ services: AppServices) {
        for controller in services.windows.controllers { controller.window?.close() }
    }
}
