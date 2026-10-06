import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHistory
import CmuxNextSettings
import Foundation
import Testing

/// The app wiring of the location trail (plans/cmux-next/history.md 4.2):
/// a window's settled focus records a location, Go Back focuses the earlier
/// tab through the registry action, and the focus it causes is absorbed.
/// Closing a workspace lists it under closed history. Windows never go on
/// screen.
@MainActor
struct LocationTrailWiringTests {
    static let key = "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a07"

    static func tree(tabs: [Int], workspaces: Bool = true) throws -> DaemonTree {
        guard workspaces else { return DaemonTree(workspaceRevision: 3, workspaces: []) }
        let tabJSON = tabs.map { #"{"kind":"pty","name":"t\#($0)","surface":\#($0),"dead":false,"cwd":"/tmp/t\#($0)"}"# }
        let json = """
        {"generation":"g1","workspace_revision":2,"workspaces":[{"active":true,"id":1,"key":"\(key)","name":"proj",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[\(tabJSON.joined(separator: ","))]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    /// `navigation.history.scope = everything`: every settled tab focus is a
    /// step (these tests walk tabs inside one workspace; the default steps
    /// only between workspaces, BACK-FORWARD-WORKSPACES-ONLY).
    static func useEverythingSteps(_ services: AppServices) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-trail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"navigation": {"history": {"scope": "everything"}}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
    }

    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func settledFocusRecordsAndGoBackReturnsToTheEarlierTab() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        try await Self.useEverythingSteps(services)
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try Self.tree(tabs: [7, 8]))
        let controller = try #require(services.windows.openWindow(workspaces: [Self.key]))
        services.windows.reconcileMembership()
        defer { controller.window?.close() }
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let (first, second) = (pane.tabs[0].id, pane.tabs[1].id)
        let trail = services.locationTrail
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        trail.now = { clock }

        await Self.settle { controller.focus.state.topology.contains(pane: pane.id) }
        controller.focus.send(.selectTab(pane: pane.id, tab: first, workspace: Self.key, source: .mouse))
        await Self.settle { trail.trail.current?.location.key.tab == first }
        clock += 5
        controller.focus.send(.selectTab(pane: pane.id, tab: second, workspace: Self.key, source: .mouse))
        await Self.settle { trail.trail.entries.count >= 2 }
        #expect(trail.trail.entries.map(\.location.key.tab) == [first, second])

        clock += 5
        #expect(services.registry.perform("focusHistoryBack"))
        await Self.settle { controller.focus.state.pane.flatMap { controller.focus.state.topology.pane($0)?.selected } == first }
        let focus = controller.focus.state
        #expect(focus.pane.flatMap { focus.topology.pane($0)?.selected } == first)
        // The Back's own focus change is absorbed: no new entry.
        #expect(trail.trail.entries.map(\.location.key.tab) == [first, second])
        #expect(trail.trail.current?.location.key.tab == first)
        #expect(trail.trail.canGoForward(isAvailable: trail.isAvailable))
        // Boundary activation is a silent no-op for keyboard and menu callers.
        #expect(services.registry.perform("focusHistoryForward"))
        await Self.settle { trail.trail.current?.location.key.tab == second }
        #expect(services.registry.perform("focusHistoryForward"))
        #expect(trail.trail.current?.location.key.tab == second)
    }

    static let workspaceKeys = [
        "1d0b7a3e-2f4c-4b1a-9e6d-0a1b2c3d4e01", "1d0b7a3e-2f4c-4b1a-9e6d-0a1b2c3d4e02", "1d0b7a3e-2f4c-4b1a-9e6d-0a1b2c3d4e03",
    ]

    /// Three workspaces with one pane and one tab each (workspace n has pane 10n+1 and tab surface 10n+2).
    static func workspacesTree() throws -> DaemonTree {
        let workspaces = workspaceKeys.enumerated().map { index, key in
            let n = (index + 1) * 10
            return """
            {"active":\(index == 0),"id":\(n),"key":"\(key)","name":"w\(index)","screens":[{"active":true,"id":\(n + 1),
            "layout":{"pane":\(n + 2),"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":\(n + 2),"name":null,
            "tabs":[{"kind":"pty","name":"t\(index)","surface":\(n + 3),"dead":false,"cwd":"/tmp/w\(index)"}]}]}]}
            """
        }
        let json = #"{"generation":"g1","workspace_revision":2,"workspaces":["# + workspaces.joined(separator: ",") + "]}"
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    /// BACK-FORWARD-WORKSPACES-ONLY: A -> B -> C, Back, Back, Forward,
    /// Forward lands on C again. Each step is a workspace switch, so the
    /// window's focus first settles once more in the workspace it leaves
    /// (the new workspace's panes arrive later); that settle is not a
    /// place the user went and must not cut off the forward entries
    /// (nxdog59: Forward stayed put or moved once, then stopped).
    @Test func forwardRetracesEveryBackBetweenWorkspaces() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let keys = Self.workspaceKeys
        services.daemon.store.apply(snapshot: try Self.workspacesTree())
        let controller = try #require(services.windows.openWindow(workspaces: keys))
        services.windows.reconcileMembership()
        defer { controller.window?.close() }
        let trail = services.locationTrail
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        trail.now = { clock }
        func paneAndTab(_ key: String) -> (String, String)? {
            guard let pane = services.daemon.store.workspaces.first(where: { $0.id == key })?.screens.first?.panes.first,
                  let tab = pane.tabs.first else { return nil }
            return (pane.id, tab.id)
        }
        func focused(_ key: String) -> Bool {
            guard let (pane, tab) = paneAndTab(key) else { return false }
            let focus = controller.focus.state
            return focus.topology.workspace == key && focus.pane == pane && focus.topology.pane(pane)?.selected == tab
        }

        for key in keys {
            clock += 5
            services.windows.select(key, in: controller.state)
            await Self.settle { controller.focus.state.topology.workspace == key }
            let (pane, tab) = try #require(paneAndTab(key))
            controller.focus.send(.selectTab(pane: pane, tab: tab, workspace: key, source: .mouse))
            await Self.settle { focused(key) && trail.trail.current?.location.workspace == key }
        }
        #expect(trail.trail.entries.map(\.location.workspace) == keys)

        let steps: [(ActionID, String)] = [("focusHistoryBack", keys[1]), ("focusHistoryBack", keys[0]),
                     ("focusHistoryForward", keys[1]), ("focusHistoryForward", keys[2])]
        for (action, expected) in steps {
            clock += 5
            #expect(services.registry.perform(action), "\(action) toward \(expected)")
            await Self.settle { focused(expected) && trail.trail.pending == nil }
            #expect(controller.state.workspaceID == expected, "\(action) toward \(expected)")
            #expect(trail.trail.current?.location.workspace == expected, "\(action) toward \(expected)")
            #expect(trail.trail.entries.map(\.location.workspace) == keys, "\(action) toward \(expected)")
        }
    }

    @Test func aClosedWorkspaceIsListedUnderClosedHistory() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        store.apply(.connected(DaemonIdentity(generation: "g1"), generationChanged: false))
        _ = services.closedWorkspaces
        store.apply(snapshot: try Self.tree(tabs: [7]))
        await Self.settle { false }
        store.apply(snapshot: try Self.tree(tabs: [], workspaces: false))
        await Self.settle { !services.closedWorkspaces.records.isEmpty }
        let record = try #require(services.closedWorkspaces.records.first)
        #expect(record.name == "proj" && record.cwd == "/tmp/t7")
        let entries = services.history.closedEntries()
        #expect(entries.contains { entry in
            if case .closed(let item) = entry.payload { return item.kind == .workspace && item.title == "proj" }
            return false
        })
    }
}
