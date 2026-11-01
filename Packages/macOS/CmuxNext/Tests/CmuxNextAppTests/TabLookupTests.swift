import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

/// Forked machines keep tab IDs and numeric handles. Routing must preserve their owner.
@MainActor
struct TabLookupTests {
    @MainActor
    private struct Fixture {
        let services: AppServices
        let remote: SSHMachineSession
        let localTab: TabModel
        let localPane: PaneModel
        let remoteTab: TabModel
        let remotePane: PaneModel

        init(resourceIDs: Bool = true) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let host = try SSHHost(destination: SSHDestination(parsing: "test@tab-lookup.invalid")).named("Tab lookup")
            remote = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                       paths: SSHPaths(root: FileManager.default.temporaryDirectory
                                           .appendingPathComponent("cn-tab-lookup-unused-\(UUID().uuidString)")),
                                       environment: { [:] }, mainWork: services.mainWork)
            services.machines.add(remote)
            let tab = TabSnapshot(surface: 1, tabResourceID: resourceIDs ? "tab_forked" : nil, title: "Forked tab")
            let pane = PaneSnapshot(id: 1, tabs: [tab])
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
            let tree = DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Forked", screens: [screen])])
            services.daemon.store.apply(snapshot: tree)
            remote.daemon.store.apply(snapshot: tree)
            localPane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            remotePane = try #require(remote.daemon.store.workspaces.first?.screens.first?.panes.first)
            localTab = try #require(localPane.tabs.first)
            remoteTab = try #require(remotePane.tabs.first)
            try #require(localTab.id == remoteTab.id && localTab !== remoteTab)
        }
    }

    @Test(arguments: [true, false])
    func duplicateIDsNeverResolveToTheFirstMachine(resourceIDs: Bool) throws {
        let fixture = try Fixture(resourceIDs: resourceIDs)
        #expect(fixture.services.locateTab(fixture.localTab.id) == nil,
                "An unscoped tab ID must refuse ambiguity rather than select this Mac's tab")
    }

    /// AgentTabs still tracks keys without their machines. Its explicit compatibility lookup
    /// keeps the existing first-match ordering until those keys include machine identity.
    @Test(arguments: [true, false])
    func explicitAnyMachineLookupPreservesFirstMatchCompatibility(resourceIDs: Bool) throws {
        let fixture = try Fixture(resourceIDs: resourceIDs)
        let local = try #require(fixture.services.locateTabOnAnyMachine(fixture.localTab.id))
        #expect(local.0 === fixture.localTab && local.1 === fixture.localPane)
        #expect(fixture.services.locateTab(fixture.localTab.id) == nil,
                "The compatibility lookup must not weaken ambiguity refusal in the default lookup")

        fixture.services.daemon.store.apply(snapshot: DaemonTree())
        let remote = try #require(fixture.services.locateTabOnAnyMachine(fixture.remoteTab.id))
        #expect(remote.0 === fixture.remoteTab && remote.1 === fixture.remotePane)
        #expect(fixture.services.locateTabOnAnyMachine("missing-tab") == nil)
    }

    @Test(arguments: [true, false])
    func aMachineScopeSelectsOnlyItsOwnTabAndPane(resourceIDs: Bool) throws {
        let fixture = try Fixture(resourceIDs: resourceIDs)
        let local = try #require(fixture.services.locateTab(fixture.localTab.id, onMachine: MachineRegistry.localID))
        let remote = try #require(fixture.services.locateTab(fixture.remoteTab.id, onMachine: fixture.remote.machineID))
        #expect(local.0 === fixture.localTab && local.1 === fixture.localPane)
        #expect(remote.0 === fixture.remoteTab && remote.1 === fixture.remotePane)
        #expect(fixture.services.locateTab("missing-tab", onMachine: fixture.remote.machineID) == nil)
    }

    @Test func modelLookupPreservesObjectIdentityAcrossMachines() throws {
        let fixture = try Fixture()
        let local = try #require(fixture.services.locateTab(model: fixture.localTab))
        let remote = try #require(fixture.services.locateTab(model: fixture.remoteTab))
        #expect(local.0 === fixture.localTab && local.1 === fixture.localPane)
        #expect(remote.0 === fixture.remoteTab && remote.1 === fixture.remotePane)
    }

    @Test func aMissingOrRemovedMachineNeverFallsBackToThisMac() throws {
        let fixture = try Fixture()
        #expect(fixture.services.locateTab(fixture.remoteTab.id, onMachine: "missing-machine") == nil)
        #expect(fixture.services.machines.removeSSH(fixture.remote.machineID) === fixture.remote)
        #expect(fixture.services.locateTab(fixture.remoteTab.id, onMachine: fixture.remote.machineID) == nil)
        #expect(fixture.services.locateTab(model: fixture.remoteTab) == nil,
                "The removed machine's model must not resolve to this Mac's matching ID or handle")
        #expect(fixture.services.locateTab(model: fixture.localTab)?.0 === fixture.localTab)
    }

    @Test func aMissingTabOnAKnownMachineNeverFallsBackToAnotherMachine() throws {
        let fixture = try Fixture()
        fixture.remote.daemon.store.apply(snapshot: DaemonTree())
        #expect(fixture.services.locateTab(fixture.localTab.id, onMachine: fixture.remote.machineID) == nil)
        #expect(fixture.services.locateTab(model: fixture.remoteTab) == nil)
        #expect(fixture.services.locateTab(fixture.localTab.id)?.0 === fixture.localTab,
                "The unscoped lookup remains usable once only one machine holds the ID")
    }

    @Test func aUniqueRemoteTabCanStillBeFoundWithoutAScope() throws {
        let fixture = try Fixture()
        fixture.services.daemon.store.apply(snapshot: DaemonTree())
        let match = try #require(fixture.services.locateTab(fixture.remoteTab.id))
        #expect(match.0 === fixture.remoteTab && match.1 === fixture.remotePane)
        #expect(fixture.services.locateTab(model: fixture.localTab) == nil,
                "A detached local model must not resolve to the surviving remote tab")
        #expect(fixture.services.locateTab("missing-tab") == nil)
    }

    @Test func aRecreatedTabDoesNotInheritTheOldModelsIdentity() throws {
        let fixture = try Fixture()
        let pane = PaneSnapshot(id: 1, tabs: [fixture.remoteTab.snapshot])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        let tree = DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Recreated", screens: [screen])])
        fixture.remote.daemon.store.apply(snapshot: DaemonTree())
        fixture.remote.daemon.store.apply(snapshot: tree)
        let replacement = try #require(fixture.services.locateTab(fixture.remoteTab.id, onMachine: fixture.remote.machineID))
        #expect(replacement.0 !== fixture.remoteTab)
        #expect(fixture.services.locateTab(model: fixture.remoteTab) == nil)
        #expect(fixture.services.locateTab(model: replacement.0)?.1 === replacement.1)
    }
    /// A remote tab's menu is built, titled and resolved on its own machine, not refused as
    /// ambiguous or read from this Mac's tab with the same id (cmuxterm-hq#5338).
    @Test func aRemoteTabMenuResolvesItsOwnMachinesTab() throws {
        let fixture = try Fixture()
        let pinned = TabSnapshot(surface: 1, tabResourceID: "tab_forked", title: "Forked tab", pinned: true)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [pinned])])
        fixture.remote.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Forked", screens: [screen])]))
        let remoteTab = try #require(fixture.remote.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        try #require(remoteTab.id == fixture.localTab.id && remoteTab.pinned && !fixture.localTab.pinned)
        AppActions.bind(fixture.services)
        let context = AppActionContext(services: fixture.services)
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: remoteTab.id))
        #expect(context.targetTab(remoteTab.id, invocation) == nil, "an unscoped id two machines share stays ambiguous")
        invocation.targetMachineID = fixture.remote.machineID
        #expect(context.targetTab(remoteTab.id, invocation)?.0 === remoteTab)
        invocation.targetMachineID = MachineRegistry.localID
        #expect(context.targetTab(remoteTab.id, invocation)?.0 === fixture.localTab)

        let menu = PaneController.tabMenu(remoteTab.id, tab: remoteTab, keepsTab: false,
                                          sameKind: NewTabKind.of(remoteTab.id, tab: remoteTab, services: fixture.services),
                                          registry: fixture.services.registry, machineID: fixture.remote.machineID)
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(items) }
        let pin = try #require(items(menu).first { ActionRegistry.menuRun(of: $0)?.id == "palette.toggleTabPin" })
        #expect(pin.title == PinStrings.unpinTab, "the remote pinned tab's row read \(pin.title)")
    }

    /// A history record carries its machine even when its tab id is duplicated by a fork.
    @Test func historyResumeUsesTheRemoteMachinePaneForDuplicateTabIDs() throws {
        let fixture = try Fixture()
        let session = AgentSession(machine: fixture.remote.machineID, provider: "claude", sessionID: "resume-remote",
                                   tab: fixture.remoteTab.id, startedAt: .now, lastActivityAt: .now)
        #expect(HistoryRestorer(services: fixture.services).paneForResume(session) === fixture.remotePane,
                "history resume must not select the local pane for a remote machine's duplicate tab id")
    }
}
