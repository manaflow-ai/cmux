import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Hot-path audit 3, H14 (2026-10-28): a window's sidebar (`SidebarBridge.init`) computed its live sections twice
/// in its first turn: `seedFromSnapshot` mapped every workspace and showed them, then the rows pass that `observe`
/// starts ran the same mapping again in the same turn and showed it. At launch every window pays it, with the main
/// thread's first frame waiting. The rows pass alone shows the live rows; the seed only lays the saved rows and
/// collapsed sections it stands in with.
///
/// The cost is measured against the same tree, so the check holds on any host: what a bridge's init adds over a
/// 10-workspace one, at 1000 workspaces, is compared with what one full rows pass (every row mapped again) adds.
/// Twice the mapping shows as about two passes; once, as about one plus one setting of the sections.
@MainActor @Suite(.serialized) struct SidebarLaunchPassCostTests {
    static func tree(workspaces: Int) -> DaemonTree {
        DaemonTree(registryID: "s-local", workspaces: (1...workspaces).map { w in
            let pane = PaneID(rawValue: UInt64(w))
            let tabs = (0..<4).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64(w * 10 + $0)), title: "zsh \($0)") }
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(w)), layout: .leaf(pane), panes: [PaneSnapshot(id: pane, tabs: tabs)])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(w)), key: WorkspaceKey(rawValue: String(format: "k%04d", w)),
                                     name: "workspace \(w)", screens: [screen])
        })
    }

    static func services(workspaces: Int) throws -> (AppServices, [String]) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(workspaces: workspaces))
        return (services, store.workspaces.map(\.id))
    }

    static func window(_ services: AppServices, listing ids: [String], id: String) throws -> WindowState {
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"\#(id)","workspace_key":"\#(ids[0])"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = ids
        return state
    }

    static func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
    }

    /// Medians of a bridge's init and of one full rows pass on it, over `runs` fresh windows.
    static func costs(workspaces: Int, runs: Int) throws -> (initUs: Double, passUs: Double, sectionSets: Int) {
        let (services, ids) = try Self.services(workspaces: workspaces)
        var inits: [Double] = [], passes: [Double] = [], sets = 0
        for run in 0..<runs {
            let state = try Self.window(services, listing: ids, id: "launch-pass-\(workspaces)-\(run)")
            _ = SidebarPerfCounters.report(reset: true)
            let start = ContinuousClock.now
            let bridge = SidebarBridge(services: services, state: state)
            inits.append(Self.microseconds(ContinuousClock.now - start))
            sets = SidebarPerfCounters.report(reset: true)["section_sets"] ?? 0
            // One rows pass that maps every row again, as the init's pass does (the feed forgets its rows).
            bridge.rowFeed.reset()
            let passStart = ContinuousClock.now
            bridge.sameTurn.syncNow(rows: true)
            passes.append(Self.microseconds(ContinuousClock.now - passStart))
            bridge.teardown()
            services.windows.registry.provisional[state.id] = nil
        }
        return (inits.sorted()[runs / 2], passes.sorted()[runs / 2], sets)
    }

    @Test func aWindowsSidebarMapsItsWorkspacesOnceInItsFirstTurn() throws {
        let small = try Self.costs(workspaces: 10, runs: 7)
        let large = try Self.costs(workspaces: 1_000, runs: 7)
        let initGrowth = large.initUs - small.initUs, passGrowth = max(large.passUs - small.passUs, 1)
        print("BENCH H14 sidebar-init workspaces=10 init_us=\(String(format: "%.0f", small.initUs)) pass_us=\(String(format: "%.0f", small.passUs))")
        print("BENCH H14 sidebar-init workspaces=1000 init_us=\(String(format: "%.0f", large.initUs)) pass_us=\(String(format: "%.0f", large.passUs)) section_sets=\(large.sectionSets)")
        print("BENCH H14 sidebar-init passes_per_init=\(String(format: "%.2f", initGrowth / passGrowth))")
        #expect(large.sectionSets <= 1, "a new window's sidebar set its sections \(large.sectionSets) times in its first turn")
        #expect(initGrowth / passGrowth < 1.75,
                "a new window's sidebar did the work of \(initGrowth / passGrowth) rows passes at 1000 workspaces (want about one)")
    }

    @Test func aNewWindowStillShowsEveryLiveRowInItsFirstTurn() throws {
        let (services, ids) = try Self.services(workspaces: 40)
        let state = try Self.window(services, listing: ids, id: "launch-pass-rows")
        let bridge = SidebarBridge(services: services, state: state)
        defer { bridge.teardown() }
        #expect(bridge.model.sections.flatMap(\.workspaces).count == 40, "the first turn lists every workspace the window owns")
    }
}
