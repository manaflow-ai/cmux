import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Observation
import Testing

/// `MachineRegistry.daemon(forTab:)` and `daemon(forPane:)` resolve this Mac's models by one
/// index lookup and remote ones without building `remoteDaemons` (field hang 08eb54bd9c:
/// observation state closures asked once per tab, and each ask built and freed that array).
@MainActor
struct MachineRegistryLookupTests {
    @MainActor
    private struct Fixture {
        let services: AppServices
        let remotes: [SSHMachineSession]
        let localTabs: [TabModel]
        let remoteTabs: [TabModel]

        init(remotes count: Int, tabs: Int) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            var remotes: [SSHMachineSession] = []
            for i in 0..<count {
                let host = try SSHHost(destination: SSHDestination(parsing: "test@lookup-\(i).invalid")).named("Lookup \(i)")
                let remote = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                               paths: SSHPaths(root: FileManager.default.temporaryDirectory
                                                   .appendingPathComponent("cn-lookup-unused-\(UUID().uuidString)")),
                                               environment: { [:] }, mainWork: services.mainWork)
                services.machines.add(remote)
                remotes.append(remote)
            }
            self.remotes = remotes
            let tree = Self.tree(tabs: tabs)
            services.daemon.store.apply(snapshot: tree)
            for remote in remotes { remote.daemon.store.apply(snapshot: tree) }
            localTabs = services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            remoteTabs = try #require(remotes.last).daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            try #require(localTabs.count == tabs && remoteTabs.count == tabs)
        }

        /// One workspace whose one pane holds `tabs` tabs.
        static func tree(tabs: Int) -> DaemonTree {
            let pane = PaneSnapshot(id: 1, tabs: (0..<tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0 + 1)), tabResourceID: ResourceID(rawValue: "tab_\($0)"), title: "Tab \($0)") })
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
            return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Lookup", screens: [screen])])
        }
    }

    @Test func eachModelResolvesToTheMachineThatListsIt() throws {
        let fixture = try Fixture(remotes: 3, tabs: 20)
        let machines = fixture.services.machines
        let last = try #require(fixture.remotes.last)
        for tab in fixture.localTabs { #expect(machines.daemon(forTab: tab) === machines.local) }
        for tab in fixture.remoteTabs { #expect(machines.daemon(forTab: tab) === last.daemon) }
        let localPane = try #require(machines.local.store.workspaces.first?.screens.first?.panes.first)
        let remotePane = try #require(last.daemon.store.workspaces.first?.screens.first?.panes.first)
        #expect(machines.daemon(forPane: localPane) === machines.local)
        #expect(machines.daemon(forPane: remotePane) === last.daemon)
        let remoteWorkspace = try #require(last.daemon.store.workspaces.first)
        #expect(machines.daemon(holding: remoteWorkspace) === last.daemon)
        // A model no machine lists still falls back to this Mac, as before.
        let elsewhere = DaemonStore()
        elsewhere.apply(snapshot: Fixture.tree(tabs: 1))
        let orphan = try #require(elsewhere.workspaces.first?.screens.first?.panes.first?.tabs.first)
        #expect(machines.daemon(forTab: orphan) === machines.local)
    }

    /// Duress: an observation state closure that resolves every tab's daemon, as the agent tab
    /// keys do, with 8 remote machines and 2,000 tabs, 20 rounds. Before: every ask built
    /// `remoteDaemons`; after: none does. Both run here, in one harness.
    @Test func resolvingEveryTabUnderObservationBuildsNoMachineList() throws {
        let fixture = try Fixture(remotes: 8, tabs: 2_000)
        let machines = fixture.services.machines
        let tabs = fixture.localTabs + fixture.remoteTabs
        func before(_ tab: TabModel) -> DaemonService {
            for daemon in machines.remoteDaemons where daemon.store.tab(surface: tab.surface) === tab { return daemon }
            return machines.local
        }
        func measure(_ resolve: (TabModel) -> DaemonService) -> Duration {
            ContinuousClock().measure {
                for _ in 0..<20 {
                    _ = withObservationTracking { tabs.reduce(0) { $0 &+ (resolve($1) === machines.local ? 1 : 0) } } onChange: {}
                }
            }
        }
        _ = measure(before)
        let old = measure(before), new = measure { machines.daemon(forTab: $0) }
        print("MachineRegistryLookup duress: 8 remotes, \(tabs.count) tabs x 20 rounds under observation: before \(old), after \(new)")
        for tab in tabs { #expect(machines.daemon(forTab: tab) === before(tab)) }
        #expect(new < old)
    }
}
