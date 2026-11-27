import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-23: "there is a lot of lag in terminal, when stuff in sidebar rearranges, we need to completely
/// get rid of this lag case from first principles". The sidebar's structural rows pass (`SidebarBridge.observe`) runs
/// whenever anything it read changes: the daemon's workspace list reordering, a store snapshot laid over again. Most
/// of those runs list exactly what the sidebar shows already (the personal or document order orders the rows; a
/// row's content comes from the row feed), and each still set every section again, walked every listed id for the
/// pending rows, and saved the sidebar snapshot: at 400 workspaces about 6 ms of main thread per run while a terminal
/// waited (sidebar-churn-typing.py). A run that lists nothing new sets no sections; one that does still shows exactly
/// what a sidebar built fresh shows.
@MainActor @Suite(.serialized) struct SidebarRowsPassCostTests {
    nonisolated static let groups = 8, perGroup = 45, loose = 40
    static var keys: [String] { (0..<(loose + groups * perGroup)).map { String(format: "k%03d", $0) } }

    /// The group of the workspace at `index` in personal order (nil: loose).
    nonisolated static func group(_ index: Int) -> WorkspaceGroupID? {
        index < loose ? nil : WorkspaceGroupID(rawValue: "g\((index - loose) / perGroup)")
    }

    /// The home session's tree: the workspaces in `daemonOrder`, personal order and groups as `groupOf` says.
    static func tree(daemonOrder: [String], names: [String: String] = [:],
                     groupOf: (Int) -> WorkspaceGroupID? = group) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: daemonOrder.enumerated().map { _, key in
            let handle = UInt64(Int(key.dropFirst())! + 1)
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: handle), key: WorkspaceKey(rawValue: key), name: names[key] ?? key)
        })
        tree.personal = PersonalState(
            groups: (0..<groups).map { WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: "g\($0)"), name: "Group \($0)", index: $0,
                                                              profile: .defaultProfile) },
            workspaces: keys.enumerated().map { index, key in
                PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index, group: groupOf(index))
            })
        return tree
    }

    static func window() throws -> WindowState {
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"rows-pass","workspace_key":"rows-pass-home"}"#.utf8))
        return WindowState(record: record)
    }

    /// One window's sidebar over 400 workspaces in 8 groups, its rows pass run once.
    static func sidebar() throws -> (AppServices, SidebarBridge) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(daemonOrder: keys))
        let state = try window()
        services.windows.registry.provisional[state.id] = keys
        let bridge = SidebarBridge(services: services, state: state)
        bridge.sameTurn.syncNow(rows: true)
        return (services, bridge)
    }

    /// The sections a sidebar built fresh over the same stores shows.
    static func fresh(_ services: AppServices) throws -> [CmuxNextSidebar.SidebarSection] {
        let state = try window()
        let bridge = SidebarBridge(services: services, state: state)
        defer { bridge.teardown() }
        bridge.sameTurn.syncNow(rows: true)
        return bridge.model.sections
    }

    static func sectionSets(_ body: () -> Void) -> Int {
        _ = SidebarPerfCounters.report(reset: true)
        body()
        return SidebarPerfCounters.report(reset: true)["section_sets"] ?? 0
    }

    @Test func aRunThatListsNothingNewSetsNoSections() throws {
        let (services, bridge) = try Self.sidebar()
        defer { bridge.teardown() }
        let shown = bridge.model.sections
        #expect(shown.flatMap(\.workspaces).count == Self.keys.count, "the fixture lists every workspace")
        let store = services.machines.local.store
        // The daemon's list reorders (a `workspace move --index 0`): the personal order still orders the rows.
        var order = Self.keys
        order.insert(order.remove(at: 377), at: 0)
        let reorder = Self.sectionSets {
            store.apply(snapshot: Self.tree(daemonOrder: order))
            bridge.sameTurn.syncNow(rows: true)
        }
        #expect(reorder == 0, "a daemon reorder that moves no row set the sections \(reorder) times")
        #expect(bridge.model.sections == shown)
        // One workspace's title changes: its row patches through the row feed; the rows pass lists nothing new.
        let rename = Self.sectionSets {
            store.apply(snapshot: Self.tree(daemonOrder: order, names: ["k123": "renamed"]))
            bridge.sameTurn.syncNow(rows: true)
        }
        #expect(rename == 0, "a title change set the sections \(rename) times")
        // The renamed row's patch waits for the display frame here: the rows and their order match a fresh sidebar's.
        #expect(try bridge.model.sections.flatMap(\.workspaces).map(\.id) == Self.fresh(services).flatMap(\.workspaces).map(\.id))
    }

    @Test func aRunThatMovesARowShowsWhatAFreshSidebarShows() throws {
        let (services, bridge) = try Self.sidebar()
        defer { bridge.teardown() }
        let store = services.machines.local.store
        // A loose workspace joins group 3 (`workspace group add`).
        let moved = Self.sectionSets {
            store.apply(snapshot: Self.tree(daemonOrder: Self.keys) { $0 == 7 ? WorkspaceGroupID(rawValue: "g3") : Self.group($0) })
            bridge.sameTurn.syncNow(rows: true)
        }
        #expect(moved >= 1, "the move never set the sections")
        let group = bridge.model.sections.flatMap(\.nodes).compactMap { node -> CmuxNextSidebar.SidebarGroup? in
            if case let .group(group) = node, group.name == "Group 3" { group } else { nil }
        }.first
        #expect(group?.workspaces.contains { $0.title == "k007" } == true, "k007 is not in Group 3")
        #expect(try bridge.model.sections == Self.fresh(services), "the moved sidebar differs from one built fresh")
    }
}
