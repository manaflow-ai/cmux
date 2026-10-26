import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// The index of tabs across machines (p06-scheduler-051): `AppServices.locateTab` finds a tab's
/// daemon with one lookup, whatever the number of machines and tabs, and the index follows each
/// store's tab keys as tabs come, go and move, and as machines join and leave the registry.
@MainActor @Suite struct MachineTabIndexTests {
    /// One workspace whose one pane holds `tabs` tabs with resource ids `tab_<machine>_<n>`.
    private static func tree(machine: Int, tabs: Int, extra: [TabSnapshot] = [], revision: UInt64 = 1) -> DaemonTree {
        let snapshots = (0..<tabs).map { n in
            TabSnapshot(surface: SurfaceID(rawValue: UInt64(n + 1)), tabResourceID: ResourceID(rawValue: "tab_\(machine)_\(n)"))
        }
        let pane = PaneSnapshot(id: 10, tabs: snapshots + extra)
        let screen = ScreenSnapshot(id: 100, layout: .leaf(10), panes: [pane])
        return DaemonTree(workspaceRevision: revision, workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w\(machine)", screens: [screen])])
    }

    @Test func tenDaemonsOfAThousandTabsFindATabInOneLookup() throws {
        let index = MachineTabIndex()
        let daemons = (0..<10).map { DaemonService(machineID: "machine-\($0)") }
        for (machine, daemon) in daemons.enumerated() {
            daemon.store.apply(snapshot: Self.tree(machine: machine, tabs: 1_000))
            index.track(daemon)
        }

        let before = index.lookups
        let found = try #require(index.daemon(holdingTab: "tab_9_999"))
        #expect(found === daemons[9])
        #expect(index.lookups - before == 1, "one lookup for the last tab of the last machine")
        #expect(index.daemon(holdingTab: "tab_0_0") === daemons[0])
        #expect(index.daemon(holdingTab: "tab_10_0") == nil)
    }

    @Test func aTabAddedLaterOrMovedToAnotherMachineIsFoundThere() throws {
        let index = MachineTabIndex()
        let (local, remote) = (DaemonService(), DaemonService(machineID: "remote"))
        index.track(local)
        index.track(remote)
        #expect(index.daemon(holdingTab: "tab_moving") == nil)

        let moving = TabSnapshot(surface: 5_000, tabResourceID: "tab_moving")
        local.store.apply(snapshot: Self.tree(machine: 0, tabs: 3, extra: [moving]))
        #expect(index.daemon(holdingTab: "tab_moving") === local)

        // The remote tree lists it before the local one drops it: each daemon holds it in turn.
        remote.store.apply(snapshot: Self.tree(machine: 1, tabs: 3, extra: [moving]))
        local.store.apply(snapshot: Self.tree(machine: 0, tabs: 3, revision: 2))
        #expect(index.daemon(holdingTab: "tab_moving") === remote)
        #expect(index.daemon(holdingTab: "tab_0_2") === local)
    }

    @Test func aForgottenDaemonsTabsAreGone() throws {
        let index = MachineTabIndex()
        let remote = DaemonService(machineID: "remote")
        remote.store.apply(snapshot: Self.tree(machine: 1, tabs: 5))
        index.track(remote)
        #expect(index.daemon(holdingTab: "tab_1_4") === remote)

        index.forget(remote)
        #expect(index.daemon(holdingTab: "tab_1_4") == nil)
        remote.store.apply(snapshot: Self.tree(machine: 1, tabs: 8, revision: 2))
        #expect(index.daemon(holdingTab: "tab_1_7") == nil, "a forgotten daemon's later tabs are not indexed")
    }

    /// A lookup that found nothing reads ``MachineTabIndex/revision`` (a tracked wait for a tab to
    /// appear observes it), and a tab listed on any machine bumps it.
    @Test func aTabListedOnAnyMachineBumpsTheRevisionAMissReads() throws {
        let index = MachineTabIndex()
        let (local, remote) = (DaemonService(), DaemonService(machineID: "remote"))
        index.track(local)
        index.track(remote)
        let before = index.revision
        #expect(index.daemon(holdingTab: "tab_1_0") == nil)
        remote.store.apply(snapshot: Self.tree(machine: 1, tabs: 1))
        #expect(index.revision != before)
        #expect(index.daemon(holdingTab: "tab_1_0") === remote)
    }

    /// The registry tracks every daemon it shows: an SSH machine's tabs are found while it is added.
    @Test func theRegistryTracksTheMachinesItAddsAndRemoves() throws {
        let machines = MachineRegistry(local: DaemonService())
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@huge-blue.tail1.ts.net")).named("lab")
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-machine-tab-index-unused")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        machines.local.store.apply(snapshot: Self.tree(machine: 0, tabs: 2))
        session.daemon.store.apply(snapshot: Self.tree(machine: 1, tabs: 2))
        #expect(machines.tabIndex.daemon(holdingTab: "tab_0_1") === machines.local)
        #expect(machines.tabIndex.daemon(holdingTab: "tab_1_1") == nil, "not added yet")

        machines.add(session)
        #expect(machines.tabIndex.daemon(holdingTab: "tab_1_1") === session.daemon)
        _ = machines.removeSSH(session.machineID)
        #expect(machines.tabIndex.daemon(holdingTab: "tab_1_1") == nil)
    }
}
