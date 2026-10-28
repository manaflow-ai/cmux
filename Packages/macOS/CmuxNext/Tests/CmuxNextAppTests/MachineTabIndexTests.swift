import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// The index of tabs across machines: `AppServices.locateTab` (``MachineTabIndex/locate(_:)``)
/// finds a tab and its pane on the machine that lists it, without reading any other machine's store,
/// whatever the number of machines and tabs. The index follows each store's net key changes as tabs
/// come, go and move, ranks machines that list the same key in the registry's order, and tells a
/// tracked caller when a machine joins or leaves.
@MainActor @Suite struct MachineTabIndexTests {
    private static let pane: PaneID = 10
    private static let otherPane: PaneID = 20

    /// One workspace whose pane 10 holds `tabs` tabs with resource ids `tab_<machine>_<n>` (pane 20
    /// is empty).
    private static func tree(machine: Int, tabs: Int, extra: [TabSnapshot] = [], revision: UInt64 = 1) -> DaemonTree {
        let snapshots = (0..<tabs).map { n in
            TabSnapshot(surface: SurfaceID(rawValue: UInt64(n + 1)), tabResourceID: ResourceID(rawValue: "tab_\(machine)_\(n)"))
        }
        let panes = [PaneSnapshot(id: pane, tabs: snapshots + extra), PaneSnapshot(id: otherPane, tabs: [])]
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(pane), b: .leaf(otherPane))
        let screen = ScreenSnapshot(id: 100, layout: layout, panes: panes)
        return DaemonTree(workspaceRevision: revision, workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w\(machine)", screens: [screen])])
    }

    private static func delta(_ tab: TabSnapshot, pane: PaneID = Self.pane, index: Int? = nil) -> TabDelta {
        TabDelta(workspace: 1, screen: 100, pane: pane, surface: tab.surface, index: index, entity: tab)
    }

    /// Set when a tracked read's observation fires.
    nonisolated private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        nonisolated var fired: Bool { lock.withLock { value } }
        nonisolated func fire() { lock.withLock { value = true } }
    }

    private static func observing(_ read: () -> Void) -> Fired {
        let fired = Fired()
        withObservationTracking(read, onChange: { fired.fire() })
        return fired
    }

    @Test func tenDaemonsOfAThousandTabsLocateEachTabAndItsPane() throws {
        let index = MachineTabIndex()
        let daemons = (0..<10).map { DaemonService(machineID: "machine-\($0)") }
        for (machine, daemon) in daemons.enumerated() {
            daemon.store.apply(snapshot: Self.tree(machine: machine, tabs: 1_000))
            index.track(daemon, as: machine == 0 ? .local : .cloud)
        }

        let (tab, pane) = try #require(index.locate("tab_9_999"))
        #expect(tab === daemons[9].store.tab(idOrResource: "tab_9_999"))
        #expect(pane === daemons[9].store.pane(holding: tab) && pane.handle == Self.pane)
        #expect(index.daemon(holdingTab: "tab_0_0") === daemons[0])
        #expect(index.daemon(holdingTab: "tab_4_500") === daemons[4])
        #expect(index.locate("tab_10_0") == nil)
    }

    /// The cost bound, by behavior: locating the last machine's tab reads no other machine's store.
    /// A walk of the machines reads each store's tab list on its way (`tab(idOrResource:)` reads
    /// `tabListRevision`), so a move on a machine before it would re-run the tracked read.
    @Test func aLocateReadsOnlyTheHoldingMachinesStore() throws {
        let index = MachineTabIndex()
        let daemons = (0..<10).map { DaemonService(machineID: "machine-\($0)") }
        for (machine, daemon) in daemons.enumerated() {
            daemon.store.apply(snapshot: Self.tree(machine: machine, tabs: 1_000))
            index.track(daemon, as: machine == 0 ? .local : .cloud)
        }
        let fired = Self.observing { _ = index.locate("tab_9_999") }

        // A move between panes on machine 5: its tab list changes, its keys do not.
        let other = daemons[5].store
        let revision = other.tabListRevision
        let moved = TabSnapshot(surface: 1, tabResourceID: "tab_5_0")
        _ = other.apply(.tabChanged(Self.delta(moved, pane: Self.otherPane, index: 0)))
        #expect(other.tabListRevision != revision, "the probe changes machine 5's tab list")
        #expect(!fired.fired, "locating machine 9's tab read machine 5's store")
        #expect(index.daemon(holdingTab: "tab_5_0") === daemons[5])
    }

    @Test func aTabAddedLaterOrMovedToAnotherMachineIsFoundThere() throws {
        let index = MachineTabIndex()
        let (local, remote) = (DaemonService(), DaemonService(machineID: "remote"))
        index.track(local, as: .local)
        index.track(remote, as: .ssh)
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

    /// Fallback ids (`surface:N`) are per machine, so two machines can list the same one: the first
    /// in the registry's order holds it, as the walk of every machine found it, whatever the order
    /// they listed it and however often one re-indexes it.
    @Test func aKeyTwoMachinesListIsHeldInRegistryOrder() throws {
        let index = MachineTabIndex()
        let (local, ssh, cloudAddedLater, cloudAddedFirst) =
            (DaemonService(), DaemonService(machineID: "ssh"), DaemonService(machineID: "vm-1"), DaemonService(machineID: "vm-2"))
        index.track(ssh, as: .ssh)
        index.track(cloudAddedFirst, as: .cloud)
        ssh.store.apply(snapshot: Self.tree(machine: 1, tabs: 0, extra: [TabSnapshot(surface: 1)]))
        cloudAddedFirst.store.apply(snapshot: Self.tree(machine: 2, tabs: 0, extra: [TabSnapshot(surface: 1)]))
        #expect(index.daemon(holdingTab: "surface:1") === cloudAddedFirst, "Cloud before SSH")

        index.track(local, as: .local)
        index.track(cloudAddedLater, as: .cloud)
        cloudAddedLater.store.apply(snapshot: Self.tree(machine: 3, tabs: 0, extra: [TabSnapshot(surface: 1)]))
        #expect(index.daemon(holdingTab: "surface:1") === cloudAddedFirst, "the Cloud machine added first")
        local.store.apply(snapshot: Self.tree(machine: 0, tabs: 0, extra: [TabSnapshot(surface: 1)]))
        #expect(index.daemon(holdingTab: "surface:1") === local)

        // The local tab changes in place and moves between panes: local still holds the key.
        _ = local.store.apply(.tabChanged(Self.delta(TabSnapshot(surface: 1, title: "renamed"))))
        _ = local.store.apply(.tabChanged(Self.delta(TabSnapshot(surface: 1), pane: Self.otherPane, index: 0)))
        local.store.apply(snapshot: Self.tree(machine: 0, tabs: 0, extra: [TabSnapshot(surface: 1), TabSnapshot(surface: 1_000)], revision: 2))
        #expect(index.daemon(holdingTab: "surface:1") === local)
        let (tab, _) = try #require(index.locate("surface:1"))
        #expect(tab === local.store.tab(idOrResource: "surface:1"))
    }

    @Test func aForgottenDaemonsTabsAreGone() throws {
        let index = MachineTabIndex()
        let remote = DaemonService(machineID: "remote")
        remote.store.apply(snapshot: Self.tree(machine: 1, tabs: 5))
        index.track(remote, as: .ssh)
        #expect(index.daemon(holdingTab: "tab_1_4") === remote)

        index.forget(remote)
        #expect(index.daemon(holdingTab: "tab_1_4") == nil)
        remote.store.apply(snapshot: Self.tree(machine: 1, tabs: 8, revision: 2))
        #expect(index.daemon(holdingTab: "tab_1_7") == nil, "a forgotten daemon's later tabs are not indexed")
    }

    /// A tracked wait for a tab to appear hears it listed on any machine.
    @Test func aTabListedOnAnyMachineWakesATrackedMiss() throws {
        let index = MachineTabIndex()
        let (local, remote) = (DaemonService(), DaemonService(machineID: "remote"))
        index.track(local, as: .local)
        index.track(remote, as: .ssh)
        let fired = Self.observing { _ = index.locate("tab_1_0") }
        remote.store.apply(snapshot: Self.tree(machine: 1, tabs: 1))
        #expect(fired.fired)
        #expect(index.daemon(holdingTab: "tab_1_0") === remote)
    }

    /// The registry tracks every daemon it shows: an SSH machine's tabs are found while it is added,
    /// and a caller that found one hears the machine leave.
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
        #expect(machines.tabIndex.locate("tab_1_1")?.0 === session.daemon.store.tab(idOrResource: "tab_1_1"))
        let fired = Self.observing { _ = machines.tabIndex.locate("tab_1_1") }
        _ = machines.removeSSH(session.machineID)
        #expect(fired.fired, "a caller that found the tab hears its machine leave")
        #expect(machines.tabIndex.locate("tab_1_1") == nil)
    }
}
