import AppKit
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
    /// A history record carries its machine even when its tab id is duplicated by a fork.
    @Test func historyResumeUsesTheRemoteMachinePaneForDuplicateTabIDs() throws {
        let fixture = try Fixture()
        let session = AgentSession(machine: fixture.remote.machineID, provider: "claude", sessionID: "resume-remote",
                                   tab: fixture.remoteTab.id, startedAt: .now, lastActivityAt: .now)
        #expect(HistoryRestorer(services: fixture.services).paneForResume(session) === fixture.remotePane,
                "history resume must not select the local pane for a remote machine's duplicate tab id")
    }
}
