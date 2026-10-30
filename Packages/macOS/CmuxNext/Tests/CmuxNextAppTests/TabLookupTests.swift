import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
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

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let host = try SSHHost(destination: SSHDestination(parsing: "test@tab-lookup.invalid")).named("Tab lookup")
            remote = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                       paths: SSHPaths(root: FileManager.default.temporaryDirectory
                                           .appendingPathComponent("cn-tab-lookup-unused-\(UUID().uuidString)")),
                                       environment: { [:] }, mainWork: services.mainWork)
            services.machines.add(remote)
            let tab = TabSnapshot(surface: 1, tabResourceID: "tab_forked", title: "Forked tab")
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

    @Test func duplicateIDsNeverResolveToTheFirstMachine() throws {
        let fixture = try Fixture()
        #expect(fixture.services.locateTab(fixture.localTab.id) == nil,
                "An unscoped tab ID must refuse ambiguity rather than select this Mac's tab")
        #expect(fixture.services.locateTab("tab_forked") == nil,
                "A resource ID shared by forked machines is ambiguous too")
    }
}
