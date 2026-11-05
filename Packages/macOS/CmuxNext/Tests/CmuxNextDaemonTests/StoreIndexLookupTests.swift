import CmuxNextCompat
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The store's by-id lookups (a workspace by resource id, a screen by id, a pane by id or
/// resource id, a pane's workspace and screen) answer from the index in O(1), and give what the
/// walk over every workspace they replace gave: after a snapshot adds, removes or renames
/// (a resource id that arrives later) records.
@MainActor
struct StoreIndexLookupTests {
    private static func tree(secondWorkspace: Bool = true, firstResource: String = "ws_a",
                             secondPaneResource: String? = nil) -> DaemonTree {
        var workspaces = [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "a"), resourceID: ResourceID(rawValue: firstResource), name: "a", screens: [
                ScreenSnapshot(id: ScreenID(rawValue: 100), resourceID: ResourceID(rawValue: "scr_1"), active: true,
                               activePane: PaneID(rawValue: 10), layout: .leaf(PaneID(rawValue: 10)),
                               panes: [PaneSnapshot(id: PaneID(rawValue: 10), resourceID: ResourceID(rawValue: "pane_10"),
                                                    tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1))])]),
            ]),
        ]
        if secondWorkspace {
            workspaces.append(WorkspaceSnapshot(id: 2, key: WorkspaceKey(rawValue: "b"), resourceID: ResourceID(rawValue: "ws_b"), name: "b", screens: [
                ScreenSnapshot(id: ScreenID(rawValue: 200), active: true, activePane: PaneID(rawValue: 20),
                               layout: .leaf(PaneID(rawValue: 20)),
                               panes: [PaneSnapshot(id: PaneID(rawValue: 20), resourceID: secondPaneResource.map(ResourceID.init(rawValue:)),
                                                    tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2))])]),
            ]))
        }
        return DaemonTree(workspaceRevision: 1, workspaces: workspaces)
    }

    private static let queries = ["ws_a", "ws_a2", "ws_b", "scr_1", "screen:100", "screen:200", "pane_10", "pane:10",
                                  "pane:20", "pane_20", "a", "b", "missing"]

    /// Every lookup equals the walk over the whole tree that it replaced.
    private static func expectMatchesWalk(_ store: DaemonStore, _ comment: String) {
        let screens = store.workspaces.flatMap(\.screens)
        let panes = screens.flatMap(\.panes)
        for id in queries {
            #expect(store.workspace(resourceID: ResourceID(rawValue: id)) === store.workspaces.first { $0.resourceID?.rawValue == id },
                    "workspace(resourceID: \(id)) \(comment)")
            #expect(store.screen(id: id) === screens.first { $0.id == id }, "screen(id: \(id)) \(comment)")
            #expect(store.screen(idOrResource: id) === screens.first { $0.id == id || $0.resourceID?.rawValue == id },
                    "screen(idOrResource: \(id)) \(comment)")
            #expect(store.pane(idOrResource: id) === panes.first { $0.id == id || $0.resourceID?.rawValue == id },
                    "pane(idOrResource: \(id)) \(comment)")
        }
        for workspace in store.workspaces {
            for screen in workspace.screens {
                #expect(store.workspace(holding: screen) === workspace, "\(comment)")
                for pane in screen.panes {
                    let location = store.location(of: pane)
                    #expect(location?.workspace === workspace && location?.screen === screen, "\(comment)")
                }
            }
        }
    }

    @Test func lookupsFollowInsertRemoveAndRename() throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree())
        Self.expectMatchesWalk(store, "first snapshot")
        #expect(store.workspace(resourceID: ResourceID(rawValue: "ws_b"))?.id == "b")
        #expect(store.screen(id: "screen:200")?.handle == ScreenID(rawValue: 200))
        #expect(store.screen(idOrResource: "scr_1")?.handle == ScreenID(rawValue: 100))
        #expect(store.pane(idOrResource: "pane:20")?.handle == PaneID(rawValue: 20))
        #expect(store.pane(idOrResource: "pane_10")?.handle == PaneID(rawValue: 10))
        let secondPane = try #require(store.pane(idOrResource: "pane:20"))
        #expect(store.location(of: secondPane)?.workspace.id == "b")

        // The second pane's resource id arrives; the first workspace's resource id changes.
        store.apply(snapshot: Self.tree(firstResource: "ws_a2", secondPaneResource: "pane_20"))
        Self.expectMatchesWalk(store, "after a rename")
        #expect(store.workspace(resourceID: ResourceID(rawValue: "ws_a")) == nil)
        #expect(store.workspace(resourceID: ResourceID(rawValue: "ws_a2"))?.id == "a")
        #expect(store.pane(idOrResource: "pane_20")?.handle == PaneID(rawValue: 20))

        // The second workspace goes: nothing of it is found, and its old pane has no location.
        let removedPane = try #require(store.pane(idOrResource: "pane_20"))
        store.apply(snapshot: Self.tree(secondWorkspace: false, firstResource: "ws_a2"))
        Self.expectMatchesWalk(store, "after a removal")
        #expect(store.workspace(resourceID: ResourceID(rawValue: "ws_b")) == nil)
        #expect(store.screen(id: "screen:200") == nil)
        #expect(store.pane(idOrResource: "pane:20") == nil)
        #expect(store.pane(idOrResource: "pane_20") == nil)
        #expect(store.location(of: removedPane) == nil)

        // It comes back.
        store.apply(snapshot: Self.tree(firstResource: "ws_a2"))
        Self.expectMatchesWalk(store, "after a re-add")
        #expect(store.workspace(resourceID: ResourceID(rawValue: "ws_b"))?.id == "b")
        #expect(store.screen(id: "screen:200") != nil)
    }

    /// A reopen wait hears a workspace whose resource id arrives in place: the workspace list itself
    /// does not change, so the wait must not observe only that list (it would sit until its timeout).
    /// The deadline is a manual clock that never moves, so only hearing the change ends the wait: a
    /// slow main actor (a loaded runner) cannot make the deadline come first.
    @Test(.timeLimit(.minutes(2))) func aReopenWaitHearsAResourceIDArriveInPlace() async throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree())
        let clock = ManualClock()
        async let wait = store.workspace(afterReopen: ResourceID(rawValue: "ws_a2"), clock: clock)
        // The deadline sleeps: the wait missed in the mirror and listens (both in its first turn).
        try await clock.waitForSleeper(within: .seconds(60))
        store.apply(snapshot: Self.tree(firstResource: "ws_a2"))
        #expect(await wait == "a")
    }

    /// A busy main actor does not lose a workspace that reached the mirror before the deadline. The
    /// deadline's child ends the wait off the main actor, but hearing the workspace needs a main-actor
    /// turn: when the deadline ends the wait first, the wait still answers what the mirror holds.
    @Test(.timeLimit(.minutes(2))) func aBusyMainActorKeepsAWorkspaceThatArrivedBeforeTheDeadline() async throws {
        let store = DaemonStore()
        store.apply(snapshot: Self.tree())
        let clock = WakeReportingClock()
        async let wait = store.workspace(afterReopen: ResourceID(rawValue: "ws_a2"), timeout: .seconds(5), clock: clock)
        try await clock.manual.waitForSleeper(within: .seconds(60))
        // One main-actor turn, as on a loaded runner: the resource id arrives in place, then the
        // deadline passes, and the turn stays busy until the deadline's sleep has returned.
        store.apply(snapshot: Self.tree(firstResource: "ws_a2"))
        clock.manual.advance(by: .seconds(5))
        Self.keepMainActorBusy(until: { clock.woke })
        #expect(await wait == "a")
    }

    /// Keeps the main actor busy (a loop with no await) until `done`, then 20 ms more for the
    /// deadline's child to run its last statements after its sleep (`return nil`, the task group's
    /// hand-off). Bounded, so a deadline that never wakes fails the test instead of hanging it.
    private static func keepMainActorBusy(until done: () -> Bool) {
        let bound = ContinuousClock.now + .seconds(30)
        while !done(), ContinuousClock.now < bound {}
        let end = ContinuousClock.now + .milliseconds(20)
        while ContinuousClock.now < end {}
    }
}

/// A ``ManualClock`` that says when a sleep on it has returned (`woke`): set on the sleeper's own
/// task after the clock woke it, so a test that keeps the main actor busy knows the sleeper runs.
private final class WakeReportingClock: Clock, Sendable {
    let manual = ManualClock()
    private let returned = Mutex(false)

    var woke: Bool { returned.withLock { $0 } }
    var now: ManualClock.Instant { manual.now }
    var minimumResolution: Duration { manual.minimumResolution }

    /// Off the main actor, where the deadline's child runs it (the Clock protocol's own requirement).
    @concurrent func sleep(until deadline: ManualClock.Instant, tolerance: Duration?) async throws {
        defer { returned.withLock { $0 = true } }
        try await manual.sleep(until: deadline, tolerance: tolerance)
    }
}
