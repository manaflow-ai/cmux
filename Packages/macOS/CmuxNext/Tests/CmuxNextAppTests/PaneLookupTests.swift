import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextRemote
import Foundation
import Testing

/// Forked machines keep pane ids as they keep tab ids. Go to Workspace's pane rows and the pane
/// actions resolve a pane on its own machine, and refuse a bare id two machines share (cmux#30755).
@MainActor
struct PaneLookupTests {
    @MainActor
    private struct Fixture {
        let services: AppServices
        let remote: SSHMachineSession
        let localPanes: [PaneModel]
        let remotePanes: [PaneModel]

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let host = try SSHHost(destination: SSHDestination(parsing: "test@pane-lookup.invalid")).named("Pane lookup")
            remote = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                       paths: SSHPaths(root: FileManager.default.temporaryDirectory
                                           .appendingPathComponent("cn-pane-lookup-unused-\(UUID().uuidString)")),
                                       environment: { [:] }, mainWork: services.mainWork)
            services.machines.add(remote)
            services.daemon.store.apply(snapshot: Self.tree(name: "Local"))
            remote.daemon.store.apply(snapshot: Self.tree(name: "Forked"))
            localPanes = try #require(services.daemon.store.workspaces.first?.screens.first?.panes)
            remotePanes = try #require(remote.daemon.store.workspaces.first?.screens.first?.panes)
            try #require(localPanes.count == 2 && remotePanes.count == 2)
            try #require(localPanes[1].id == remotePanes[1].id && localPanes[1] !== remotePanes[1])
        }

        /// One workspace with two panes, so Go to Workspace lists both.
        private static func tree(name: String) -> DaemonTree {
            let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "\(name) one")])
            let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "\(name) two")])
            let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
            let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
            return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: name, screens: [screen])])
        }

        func invocation(_ id: String, machine: String?) -> ActionInvocation {
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: id), origin: .user)
            invocation.targetMachineID = machine
            return invocation
        }
    }

    @Test func aBarePaneIDTwoMachinesShareIsRefusedNotTheFirstMachines() throws {
        let fixture = try Fixture()
        let id = fixture.remotePanes[1].id
        #expect(fixture.services.locatePane(id) == nil, "an unscoped shared pane id must refuse ambiguity")
        let context = AppActionContext(services: fixture.services)
        #expect(context.daemonPane(fixture.invocation(id, machine: nil)) == nil)
        #expect(ActionRouting.daemon(for: fixture.invocation(id, machine: nil), daemons: fixture.services.machines.daemons,
                                     windowMachine: { _ in nil }) == nil,
                "routing must not pick the first daemon holding a shared pane id")
    }

    @Test func aMachineScopeSelectsOnlyItsOwnPane() throws {
        let fixture = try Fixture()
        let id = fixture.remotePanes[1].id
        let context = AppActionContext(services: fixture.services)
        #expect(context.daemonPane(fixture.invocation(id, machine: fixture.remote.machineID)) === fixture.remotePanes[1])
        #expect(context.daemonPane(fixture.invocation(id, machine: MachineRegistry.localID)) === fixture.localPanes[1])
        #expect(fixture.services.locatePane(id, onMachine: fixture.remote.machineID) === fixture.remotePanes[1])
        let routed = ActionRouting.daemon(for: fixture.invocation(id, machine: fixture.remote.machineID),
                                          daemons: fixture.services.machines.daemons, windowMachine: { _ in nil })
        #expect(routed === fixture.remote.daemon)
    }

    @Test func aDisconnectedOwnerRefusesAndNeverFallsBackToThisMac() throws {
        let fixture = try Fixture()
        let id = fixture.remotePanes[1].id
        #expect(fixture.services.machines.removeSSH(fixture.remote.machineID) === fixture.remote)
        let context = AppActionContext(services: fixture.services)
        #expect(context.daemonPane(fixture.invocation(id, machine: fixture.remote.machineID)) == nil)
        #expect(fixture.services.locatePane(id, onMachine: fixture.remote.machineID) == nil)
        #expect(fixture.services.locatePane(id) === fixture.localPanes[1],
                "the unscoped lookup stays usable once only one machine holds the id")
    }

    /// Each pane row carries its machine, the two rows stay distinct, and choosing the remote
    /// row runs `pane.focus` on the remote machine.
    @Test func goToWorkspacePaneRowsCarryAndPassTheirMachine() throws {
        let fixture = try Fixture()
        let machine = fixture.remote.machineID
        func workspace(_ id: String, machine: String?) -> ControlWorkspaceInfo {
            let panes = ["pane-1", "pane-2"].enumerated().map { index, pane in
                ControlPaneInfo(id: pane, handle: "\(index + 1)", tabs: [ControlTabInfo(id: "tab-\(index)", surface: "\(index + 1)",
                                                                                         kind: "terminal", title: "zsh")])
            }
            var info = ControlWorkspaceInfo(id: id, handle: "1", name: id, screens: [ControlScreenInfo(id: "s1", handle: "1", panes: panes)])
            info.machine = machine
            return info
        }
        var topology = ControlTopology()
        topology.workspaces = [workspace("ws-local", machine: nil), workspace("ws-forked", machine: machine)]
        let panes = PaletteNavigationEntries.entries(topology, groups: [], lastActive: [:]).filter { $0.kind == .pane }
        #expect(panes.map(\.machineID) == [nil, nil, machine, machine])
        #expect(Set(panes.map(\.itemID)).count == 4, "same-id panes on two machines must be distinct rows")

        var focused: [ActionInvocation] = []
        fixture.services.registry.bind("pane.focus", invoke: { focused.append($0) })
        let source = AppPaletteNavigationSource(services: fixture.services)
        source.open(panes[3])
        source.open(panes[1])
        #expect(focused.map(\.targetMachineID) == [machine, MachineRegistry.localID])
        #expect(focused.map { $0.target?.id } == ["pane-2", "pane-2"])
    }

    /// The strip's "+" (`newTab.default` -> `daemonPane`) and a tab's double-click zoom (`toggleSplitZoom`)
    /// send this pane's paneKey; scoped to the pane's own machine they still find it while a fork with
    /// the same ids is connected, instead of being refused as ambiguous.
    @Test func paneChromeRunsAreScopedToTheirOwnMachine() throws {
        let fixture = try Fixture()
        let context = AppActionContext(services: fixture.services)
        for (pane, machine) in [(fixture.localPanes[1], MachineRegistry.localID), (fixture.remotePanes[1], fixture.remote.machineID)] {
            var runs: [ActionInvocation] = []
            StripNewTab.request(pane: pane.id, machineID: fixture.services.daemon(for: pane).machineID) { runs.append($1) }
            runs.append(PaneController.zoomInvocation(pane: pane.id, machineID: fixture.services.daemon(for: pane).machineID))
            #expect(runs.map(\.targetMachineID) == [machine, machine])
            for run in runs { #expect(context.daemonPane(run) === pane) }
        }
        #expect(context.daemonPane(PaneController.zoomInvocation(pane: fixture.localPanes[1].id)) == nil,
                "a bare paneKey two machines share stays ambiguous")
    }

    /// An agent tab's open in editor (`file.open` where `editor`, also Session Info Sources and the
    /// Diff page) and its preview open run on the agent pane's own machine.
    @Test func agentFileAndPreviewOpensAreScopedToTheirOwnMachine() throws {
        let fixture = try Fixture()
        let context = AppActionContext(services: fixture.services)
        var runs: [ActionInvocation] = []
        fixture.services.registry.bind(.fileOpen, invoke: { runs.append($0) })
        fixture.services.registry.bind(.openBrowser, invoke: { runs.append($0) })
        for (pane, machine) in [(fixture.localPanes[1], MachineRegistry.localID), (fixture.remotePanes[1], fixture.remote.machineID)] {
            runs = []
            #expect(fixture.services.registry.openAgentFile(path: "/tmp/a.swift", target: .editor, pane: pane.id, machineID: machine))
            #expect(fixture.services.registry.openAgentPreview(URL(fileURLWithPath: "/tmp/a.html"), pane: pane.id, machineID: machine))
            #expect(runs.map(\.targetMachineID) == [machine, machine])
            #expect(runs.map { $0["where"]?.stringValue } == ["editor", nil])
            for run in runs { #expect(context.daemonPane(run) === pane) }
        }
    }
}
