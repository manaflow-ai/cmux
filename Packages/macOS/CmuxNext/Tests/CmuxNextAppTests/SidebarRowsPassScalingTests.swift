import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Workspace scaling (gap:theme:lp-taste-workspace-scaling-constant-time): what one workspace's change costs the
/// window's sidebar must not grow with the workspaces it lists. A tab opened (Cmd-T) or a pane split (Cmd-D) in ONE
/// workspace wakes no structural rows pass and maps at most that workspace's row, at 8 and at 5,000 workspaces.
/// Count-based (`SidebarPerfCounters` `row_maps`), never a timing. The fixture is `SidebarRowsPassListOnlyTests`'
/// with the size as a parameter.
@MainActor @Suite(.serialized) struct SidebarRowsPassScalingTests {
    static let changed = 5

    static func keys(_ n: Int) -> [String] { (0..<n).map { String(format: "k%05d", $0) } }

    static func tree(_ n: Int) -> DaemonTree {
        let keys = keys(n)
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { SidebarRowsPassListOnlyTests.workspace($1, index: $0) })
        tree.personal = PersonalState(groups: [], workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index, group: nil)
        })
        return tree
    }

    /// Cmd-D's daemon event: a second pane joins workspace `index`'s screen.
    static func paneAdded(in index: Int, sequence: UInt64) -> DaemonEventEnvelope {
        let base = UInt64(index + 1) * 100
        let pane = PaneID(rawValue: base + 50)
        return DaemonEventEnvelope(sequence: sequence, event: .paneAdded(PaneDelta(
            workspace: WorkspaceHandle(rawValue: UInt64(index + 1)), screen: ScreenID(rawValue: base), pane: pane, index: 1,
            entity: PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: base + 51), kind: .pty, cwd: "/tmp/split")]),
            clientTransactionID: nil)))
    }

    @MainActor final class Fixture {
        let services: AppServices
        let state: WindowState
        let feed: SidebarRowFeed
        final class Frames { var work: [@MainActor @Sendable () -> Void] = [] }
        let frames = Frames()
        private(set) var listed: [SidebarWorkspace] = []
        private(set) var woke = false
        private var runs = 0

        init(_ n: Int) throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: SidebarRowsPassScalingTests.tree(n))
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"rows-pass-scaling","workspace_key":"rows-pass-scaling-home"}"#.utf8))
            state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = SidebarRowsPassScalingTests.keys(n)
            feed = SidebarRowFeed(schedule: { [frames] work in frames.work.append(work) })
            run(); frame(); run(); frame() // the first pass names every row; the second is the steady state
        }

        func run() {
            woke = false
            runs += 1
            let run = runs
            let sections = withObservationTracking {
                SidebarBridge.passSections(services, window: state, feed: feed, rows: feed.rowSource).0
            } onChange: { [weak self] in
                MainActor.assumeIsolated { if self?.runs == run { self?.woke = true } }
            }
            listed = feed.fill(sections).flatMap(\.workspaces)
        }

        func frame() {
            let work = frames.work
            frames.work.removeAll()
            work.forEach { $0() }
        }
    }

    private func measure(_ n: Int, _ action: String, _ event: (UInt64) -> DaemonEventEnvelope) throws {
        let fixture = try Fixture(n)
        defer { fixture.feed.reset() }
        #expect(fixture.listed.count == n, "the fixture lists every workspace")
        _ = SidebarPerfCounters.report(reset: true)
        _ = fixture.services.machines.local.store.apply(batch: [event(1)])
        fixture.frame()
        let counters = SidebarPerfCounters.report(reset: true)
        let maps = counters["row_maps"] ?? 0
        print("SIDEBAR-ROWS-SCALING action=\(action) n=\(n) woke=\(fixture.woke) row_maps=\(maps) rows_walked=\(counters["rows_walked"] ?? 0)")
        #expect(!fixture.woke, "\(action) in one workspace ran the rows pass over all \(n) workspaces")
        #expect(maps <= 1, "\(action) in one workspace mapped \(maps) rows at \(n) workspaces")
    }

    @Test(arguments: [8, 5000]) func aTabOpenedInOneWorkspaceCostsOneRow(n: Int) throws {
        // A surface id above every fixture id at 5,000 workspaces.
        let tab = TabSnapshot(surface: SurfaceID(rawValue: 99_000_001), kind: .pty, cwd: "/tmp/front")
        try measure(n, "Cmd-T") { SidebarRowsPassListOnlyTests.openedFirst(tab, in: Self.changed, sequence: $0) }
    }

    @Test(arguments: [8, 5000]) func aPaneSplitInOneWorkspaceCostsOneRow(n: Int) throws {
        try measure(n, "Cmd-D") { Self.paneAdded(in: Self.changed, sequence: $0) }
    }
}
