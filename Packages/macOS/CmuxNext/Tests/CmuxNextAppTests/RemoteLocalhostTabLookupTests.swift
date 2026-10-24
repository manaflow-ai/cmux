import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemoteLocalhostService
import Foundation
import Testing
@testable import CmuxNextApp

/// `RemoteLocalhostService.tab(id:)` is the browser tab cache's `tabModel` fallback
/// (`cache.findTab`) and the omnibar machine chip's lookup: render and feed passes call it once
/// per tab. It walked every machine's workspaces, screens, panes and tabs, so a pass was quadratic
/// in the tabs, and a miss (a key no store holds) walked them all: up to 120 ms main-thread
/// stalls in the STRESS session (60 workspaces; sweep group `remote-localhost-lookups`:
/// `sidebar.profileControl.show`, `newTab.atStart`, ...). It reads each store's index now.
@MainActor
struct RemoteLocalhostTabLookupTests {
    /// `workspaces` workspaces of one screen with 12 panes of 6 tabs each (the STRESS measured
    /// workspace's shape), handles and surfaces numbered from `first`; returns the tab ids too.
    static func tree(workspaces: Int, first: UInt64) -> (tree: DaemonTree, ids: [String]) {
        var next = first
        func take() -> UInt64 {
            defer { next += 1 }
            return next
        }
        var ids: [String] = []
        let models = (0..<workspaces).map { index -> WorkspaceSnapshot in
            let panes = (0..<12).map { _ in
                PaneSnapshot(id: PaneID(rawValue: take()), tabs: (0..<6).map { _ in
                    let surface = SurfaceID(rawValue: take())
                    ids.append("surface:\(surface.rawValue)")
                    return TabSnapshot(surface: surface)
                })
            }
            let layout = panes.dropFirst().reduce(LayoutNode.leaf(panes[0].id)) { chain, pane in
                .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: chain, b: .leaf(pane.id))
            }
            let screen = ScreenSnapshot(id: ScreenID(rawValue: take()), layout: layout, panes: panes)
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: take()), key: nil, name: "w\(index)", screens: [screen])
        }
        return (DaemonTree(workspaces: models), ids)
    }

    /// Each tab id resolves to its own store's record, on this Mac and on another machine; an
    /// id no store holds resolves to nothing.
    @Test func everyTabResolvesToItsOwnRecordOnItsMachine() throws {
        let machines = MachineRegistry(local: DaemonService())
        let remote = try #require(machines.anyDaemon(machine: try TabMachineColorTests.sshMachine(machines).machineID))
        let (localTree, localIDs) = Self.tree(workspaces: 2, first: 1)
        let (remoteTree, remoteIDs) = Self.tree(workspaces: 2, first: 100_000)
        machines.local.store.apply(snapshot: localTree)
        remote.store.apply(snapshot: remoteTree)
        let localhost = RemoteLocalhostService(machines: machines, environment: [:])

        for (ids, store) in [(localIDs, machines.local.store), (remoteIDs, remote.store)] {
            for id in ids {
                let tab = try #require(localhost.tab(id: id), "tab \(id)")
                #expect(tab === store.tab(surface: tab.surface), "tab \(id) is its own store's record")
                #expect(tab.id == id)
            }
        }
        #expect(localhost.tab(id: "surface:999999999") == nil)
        #expect(localhost.tab(id: "tab_gone") == nil)
    }

    /// The chip shows only for a loopback page of another machine's tab: this Mac's tabs never
    /// get one (decided before the URL's host is parsed), another machine's non-loopback page
    /// neither.
    @Test func onlyAnotherMachinesLoopbackPageGetsAChip() throws {
        let machines = MachineRegistry(local: DaemonService())
        let remote = try #require(machines.anyDaemon(machine: try TabMachineColorTests.sshMachine(machines).machineID))
        machines.local.store.apply(snapshot: Self.tree(workspaces: 1, first: 1).tree)
        remote.store.apply(snapshot: Self.tree(workspaces: 1, first: 100_000).tree)
        let localhost = RemoteLocalhostService(machines: machines, environment: [:])
        let localTab = try #require(machines.local.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let remoteTab = try #require(remote.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let loopback = URL(string: "http://localhost:3000/")
        let site = URL(string: "https://example.com/")

        #expect(localhost.badge(for: localTab, url: loopback, engine: .cef) == nil, "this Mac's localhost")
        #expect(localhost.badge(for: localTab, url: site, engine: .cef) == nil)
        #expect(localhost.badge(for: remoteTab, url: site, engine: .cef) == nil, "not a loopback page")
        #expect(localhost.badge(for: remoteTab, url: nil, engine: .cef) == nil)
        #expect(localhost.badge(for: remoteTab, url: loopback, engine: .cef) != nil, "another machine's loopback page")
        #expect(localhost.badge(for: remoteTab, url: loopback, engine: .webkit) != nil)
    }

    /// The same number of lookups (each tab once, then as many misses) costs about the same in a
    /// one-workspace store (72 tabs) and in a STRESS-sized one (60 workspaces, 4320 tabs). A walk
    /// over the tabs makes each lookup about 60 times as costly in the larger store; an index
    /// lookup costs the same. The bound of 8 sits between the two with room for timing noise on
    /// either side (the fastest of five runs of each is compared).
    @Test func lookupCostDoesNotGrowWithTheTabs() throws {
        let lookups = 1_000
        func cost(workspaces: Int) -> (Duration, Int) {
            let machines = MachineRegistry(local: DaemonService())
            let (tree, ids) = Self.tree(workspaces: workspaces, first: 1)
            machines.local.store.apply(snapshot: tree)
            let localhost = RemoteLocalhostService(machines: machines, environment: [:])
            // Spread over the whole store, so a walk visits half the tabs per hit on average.
            let hits = (0..<lookups).map { ids[$0 * ids.count / lookups] }
            let misses = (0..<lookups).map { "tab_missing_\($0)" }
            let clock = ContinuousClock()
            var found = 0
            var fastest = Duration.seconds(3_600)
            for _ in 0..<5 {
                found = 0
                let elapsed = clock.measure {
                    for id in hits where localhost.tab(id: id) != nil { found += 1 }
                    for id in misses where localhost.tab(id: id) != nil { found += 1 }
                }
                fastest = min(fastest, elapsed)
            }
            return (fastest, found)
        }
        let (small, smallFound) = cost(workspaces: 1)
        let (large, largeFound) = cost(workspaces: 60)
        #expect(smallFound == lookups && largeFound == lookups, "every hit resolves, no miss does")
        let ratio = large / max(small, .nanoseconds(1))
        #expect(ratio < 8, "a lookup in a 4320-tab store cost \(ratio)x one in a 72-tab store (\(large) vs \(small) for \(2 * lookups) lookups)")
    }
}
