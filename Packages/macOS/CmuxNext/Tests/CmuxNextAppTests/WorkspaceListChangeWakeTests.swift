import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// WORKSPACE LIST 800 (SESSION 800, 2026-11-10): in the person's session (826 workspaces) each workspace close blocked
/// the main thread about 100 ms and each new workspace two times; at 60 workspaces nothing blocked. A change of the
/// workspace LIST (one workspace added, one closed) must wake the observers of the changed workspace and of the list,
/// never one observer per workspace of the session (CLAUDE.md "Go past Chrome": a local model change is O(changed
/// items), never O(session)).
///
/// Each test applies the daemon's own event (`workspace-added`, `workspace-closed`: what `DaemonStore.drain` applies
/// after the key) in a whole window (`LargeSessionWindowFixture`, every observer the app starts) and counts the
/// observation trackings the change wakes (`ObservationWakes`), by the `#fileID:#line` of each woken observer. The
/// closed workspace is a hidden one, so the count is the list change's, not the close flow's.
///
/// Sizes: `large` (60) always, and each other size `CMUX_TEST_SESSION_SIZES` names (826 runs on a mini, never by
/// default: `SessionFixtureSize`). Each count has a bound with no session size in it, and the counts of every size
/// run must be equal.
///
///     CMUX_TEST_SESSION_SIZES=large,real swift test --filter WorkspaceListChangeWakeTests
@MainActor @Suite(.serialized) struct WorkspaceListChangeWakeTests {
    typealias Fixture = LargeSessionWindowFixture

    static let sizes: [SessionFixtureSize] = [.large] + SessionFixtureSize.arms.filter { $0 != .large }

    /// The most observers one list change may wake, at any session size: the list's own observers (the sidebar, the
    /// window registry's readers, the app services' list watches) and the changed workspace's.
    static let wakeBound = 150

    /// The most link-place observations (one per workspace: `AgentPaneLinkPlaces.follow`) one list change may wake.
    /// A woken one names its workspace again (its name, every pane and every tab).
    static let linkPlaceBound = 64

    /// The site prefix of the link places' per-workspace observations.
    static let linkPlaces = "CmuxNextAgentPane/AgentPaneLinkPlaces.swift"

    /// What one list change woke and what the sidebar did for it.
    struct Change: Sendable {
        var wakes: [String: Int] = [:]
        var sidebar: [String: Int] = [:]

        var total: Int { wakes.values.reduce(0, +) }
        func wakes(of prefix: String) -> Int { wakes.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +) }
    }

    struct Counts: Sendable {
        var added = Change()
        var closed = Change()
    }

    /// One measured window per size, for the whole suite: a window of 826 workspaces takes seconds to open.
    private static var measured: [SessionFixtureSize: Counts] = [:]

    /// A workspace the session does not hold: one screen, one pane, one terminal.
    private static func newWorkspace() -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: 900_001), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 900_001), title: "zsh")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 900_001), layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 900_001), key: WorkspaceKey(rawValue: "list-change-new"),
                                 name: "list change", screens: [screen])
    }

    /// Applies `change` to `store` and returns what it woke in its own turn and what the sidebar did until the main
    /// actor was idle again.
    private static func measure(_ store: DaemonStore, _ change: @MainActor () -> Void) async -> Change {
        await Fixture.drainMain()
        _ = SidebarView.perfCounters(reset: true)
        let wakes = ObservationWakes()
        ObservationWakes.$current.withValue(wakes) { change() }
        await Fixture.drainMain()
        let sidebar = SidebarView.perfCounters(reset: true)
        await Fixture.drainMain()
        return Change(wakes: wakes.bySite, sidebar: sidebar)
    }

    /// One workspace added at the end of the list, then one hidden workspace (the fifth) closed, in a session of `size`.
    static func counts(_ size: SessionFixtureSize) async throws -> Counts {
        if let counts = measured[size] { return counts }
        let counts = try await Fixture.withWindow(size) { store -> Counts in
            let entity = newWorkspace()
            let added = await measure(store) {
                _ = store.apply(.workspaceAdded(WorkspaceDelta(workspace: entity.id, index: size.workspaces, entity: entity,
                                                              workspaceRevision: store.workspaceRevision + 1)))
            }
            try #require(store.workspaces.count == size.workspaces + 1, "fixture: the event added no workspace")
            let hidden = Fixture.tree(size).workspaces[4]
            let closed = await measure(store) {
                _ = store.apply(.workspaceClosed(WorkspaceDelta(workspace: hidden.id, index: 4, entity: hidden,
                                                               workspaceRevision: store.workspaceRevision + 1)))
            }
            try #require(store.workspaces.count == size.workspaces, "fixture: the event closed no workspace")
            try #require(!store.workspaces.contains { $0.key == hidden.key }, "fixture: the closed workspace is still listed")
            return Counts(added: added, closed: closed)
        }
        measured[size] = counts
        // Every count, also when the test passes: which observers one list change wakes, at each size.
        let rows = ["section_sets", "rebuilds", "row_maps", "row_invalidations", "order_builds", "layout_rows", "list_reloads", "ffi_calls"]
        for (name, change) in [("added", counts.added), ("closed", counts.closed)] {
            for site in change.wakes.keys.sorted() { print("WorkspaceListChange \(size.rawValue) \(name) wakes \(site): \(change.wakes[site] ?? 0)") }
            print("WorkspaceListChange \(size.rawValue) \(name) wakes total: \(change.total); sidebar: "
                + rows.map { "\($0) \(change.sidebar[$0] ?? 0)" }.joined(separator: ", "))
        }
        return counts
    }

    /// The sites that woke more often at a larger size than at `large`, largest growth first.
    private static func grew(_ changes: [SessionFixtureSize: Change]) -> [String] {
        guard let small = changes[.large]?.wakes else { return [] }
        return changes.filter { $0.key != .large }.flatMap { size, change in
            change.wakes.filter { $0.value > small[$0.key, default: 0] }.sorted { $0.value > $1.value }
                .map { "\($0.key) \(small[$0.key, default: 0]) -> \($0.value) at \(size.rawValue)" }
        }
    }

    private static func check(_ name: String, _ pick: (Counts) -> Change) async throws {
        var changes: [SessionFixtureSize: Change] = [:]
        for size in sizes {
            let change = pick(try await counts(size))
            changes[size] = change
            #expect(change.total > 0, "fixture: one workspace \(name) woke no observer at \(size.rawValue) (the counter is not wired)")
            #expect(change.total <= wakeBound,
                    "one workspace \(name) in a session of \(size.workspaces) woke \(change.total) observers (bound \(wakeBound))")
        }
        let totals = changes.map { "\($0.key.rawValue) \($0.value.total)" }.sorted()
        #expect(Set(changes.values.map(\.total)).count == 1,
                "observers one workspace \(name) wakes grow with the session: \(totals); grew: \(grew(changes))")
    }

    @Test(.timeLimit(.minutes(10)))
    func oneWorkspaceAddedWakesAsManyObserversInALargerSession() async throws {
        try await Self.check("added") { $0.added }
    }

    @Test(.timeLimit(.minutes(10)))
    func oneWorkspaceClosedWakesAsManyObserversInALargerSession() async throws {
        try await Self.check("closed") { $0.closed }
    }

    /// The link places name a workspace again when its own observation wakes. A list change wakes the changed
    /// workspace's at most, never one per workspace of the session.
    @Test(.timeLimit(.minutes(10)))
    func aListChangeNamesTheLinkPlacesOfNoOtherWorkspace() async throws {
        var named: [String: Int] = [:]
        for size in Self.sizes {
            let counts = try await Self.counts(size)
            for (name, change) in [("added", counts.added), ("closed", counts.closed)] {
                let woken = change.wakes(of: Self.linkPlaces)
                named["\(size.rawValue) \(name)"] = woken
                #expect(woken <= Self.linkPlaceBound,
                        "one workspace \(name) in a session of \(size.workspaces) named the link places of \(woken) workspaces again (bound \(Self.linkPlaceBound))")
            }
        }
        #expect(Set(named.values).count <= 1 || named.values.allSatisfy { $0 <= 1 },
                "workspaces whose link places one list change names again grow with the session: \(named.sorted { $0.key < $1.key })")
    }
}
