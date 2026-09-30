import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A window exists only while it holds a workspace (user decision
/// 2026-09-30), end to end through `WindowManager`: a daemon delta closes
/// the window in the same turn, a new workspace opens or fills its window
/// only once mirrored, moving every workspace of a window out moves the
/// window, and a storm of moves, closes and daemon changes never leaves a
/// window without a workspace. Windows are never put on screen.
@MainActor
struct WindowLifecycleTests {
    static let keys = (1...4).map { WorkspaceKey(rawValue: "5d1e8f0a-3c2b-4a19-8e7d-6b5a4c3d2e1\($0)") }

    private static func services(workspaces count: Int) -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        apply(services, keys: Array(keys.prefix(count)))
        return services
    }

    private static func apply(_ services: AppServices, keys: [WorkspaceKey]) {
        let snapshots = keys.map { key in
            let index = Self.keys.firstIndex(of: key)! + 1
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index)), key: key, name: "w\(index)")
        }
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 100, workspaces: snapshots))
    }

    private static func id(_ index: Int) -> String { keys[index - 1].rawValue }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    private static func expectConsistent(_ services: AppServices, _ step: String = "") {
        let windows = services.windows!
        #expect(WindowInvariants.problems(windows).isEmpty, "\(step): \(WindowInvariants.problems(windows))")
        for controller in windows.controllers {
            #expect(!windows.registry.members(of: controller.state.id).isEmpty, "\(step): \(controller.state.id) shows no workspace")
        }
    }

    private static func closeAll(_ services: AppServices) {
        for controller in services.windows.controllers { controller.window?.close() }
    }

    @Test func aDaemonDeltaClosesTheWindowInTheSameTurn() {
        let services = Self.services(workspaces: 2)
        let a = services.windows.openWindow(workspaces: [Self.id(1)])
        let b = services.windows.openWindow(workspaces: [Self.id(2)])
        services.windows.reconcileMembership()
        // Another client closes w2: no reconcile call, no await.
        Self.apply(services, keys: [Self.keys[0]])
        #expect(services.windows.controllers.map(\.state.id) == [a?.state.id])
        #expect(services.windows.registry.value.window(b?.state.id ?? "") == nil)
        // And the last one: the app keeps running with no window.
        Self.apply(services, keys: [])
        #expect(services.windows.controllers.isEmpty)
        #expect(services.windows.registry.value.windows.isEmpty)
        #expect(services.windows.invariantViolations == 0)
    }

    @Test func aNewWindowOpensOnlyOnceItsWorkspaceIsMirrored() {
        let services = Self.services(workspaces: 1)
        let a = try? #require(services.windows.openWindow(workspaces: [Self.id(1)]))
        services.windows.reconcileMembership()
        // Cmd-N / Dock / CLI with no window: claimed before the create.
        services.windows.claimNew(workspaceID: Self.id(2), window: "fresh")
        #expect(services.windows.registry.value.window("fresh") == nil)
        #expect(services.windows.controllers.count == 1)
        Self.apply(services, keys: Array(Self.keys.prefix(2)))
        #expect(services.windows.registry.members(of: "fresh") == [Self.id(2)])
        #expect(services.windows.controller(for: "fresh")?.state.workspaceID == Self.id(2))
        #expect(services.windows.registry.members(of: a?.state.id ?? "") == [Self.id(1)])
        Self.expectConsistent(services)
        Self.closeAll(services)
    }

    @Test func aClaimOnAnOpenWindowLandsAndIsSelectedThere() throws {
        let services = Self.services(workspaces: 2)
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1)]))
        let b = try #require(services.windows.openWindow(workspaces: [Self.id(2)]))
        services.windows.reconcileMembership()
        services.windows.didActivate(b)
        services.windows.claimNew(workspaceID: Self.id(3), window: a.state.id)
        Self.apply(services, keys: Array(Self.keys.prefix(3)))
        #expect(services.windows.registry.members(of: a.state.id) == [Self.id(1), Self.id(3)])
        #expect(a.state.workspaceID == Self.id(3))
        #expect(services.windows.registry.members(of: b.state.id) == [Self.id(2)])
        Self.closeAll(services)
    }

    @Test func aWindowForAnUnmirroredWorkspaceStaysOffScreenUntilItsContentShows() async throws {
        let services = Self.services(workspaces: 1)
        services.windows.reconcileMembership()
        // A tab moved to a new workspace in a new window: the command
        // answered before the delta.
        let torn = try #require(services.windows.openWindow(workspaces: [Self.id(2)]))
        #expect(services.windows.awaitingContent[torn.state.id] != nil)
        #expect(torn.content == nil)
        Self.apply(services, keys: Array(Self.keys.prefix(2)))
        await Self.settle { torn.content != nil }
        #expect(torn.content?.workspace.id == Self.id(2))
        #expect(services.windows.awaitingContent[torn.state.id] == nil)
        Self.closeAll(services)
    }

    @Test func movingEveryWorkspaceOfAWindowToANewWindowMovesThatWindow() throws {
        let services = Self.services(workspaces: 2)
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1)]))
        let b = try #require(services.windows.openWindow(workspaces: [Self.id(2)]))
        services.windows.didActivate(a)
        #expect(services.registry.perform("moveWorkspaceToNewWindow",
                                          invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: Self.id(1)))))
        #expect(services.windows.controllers.map(\.state.id) == [a.state.id, b.state.id])
        #expect(services.windows.registry.members(of: a.state.id) == [Self.id(1)])
        Self.expectConsistent(services)
        Self.closeAll(services)
    }

    @Test func anUnregisteredOnScreenWindowIsReported() throws {
        let services = Self.services(workspaces: 1)
        let a = try #require(services.windows.openWindow(workspaces: [Self.id(1)]))
        #expect(WindowInvariants.problems(services.windows).isEmpty)
        services.windows.registry.apply { registry in
            registry = WindowRegistry()
            return WindowRegistry.Changes()
        }
        #expect(WindowInvariants.problems(services.windows) == ["window \(a.state.id) is on screen but not registered"])
        a.window?.close()
    }

    @Test func aStormOfMovesClosesAndDaemonChangesNeverShowsAnEmptyWindow() {
        for seed in UInt64(1)...8 {
            var rng = WindowRegistryRaceTests.Seeded(state: seed)
            let services = Self.services(workspaces: 4)
            let windows = services.windows!
            windows.openWindow(workspaces: [Self.id(1), Self.id(2)])
            windows.openWindow(workspaces: [Self.id(3), Self.id(4)])
            windows.reconcileMembership()
            var live = Self.keys
            for step in 0..<60 {
                let label = "seed \(seed) step \(step)"
                let open = windows.registry.value.openWindows.map(\.id)
                let ids = live.map(\.rawValue)
                switch Int.random(in: 0..<5, using: &rng) {
                case 0 where !open.isEmpty && !ids.isEmpty:
                    windows.moveWorkspaces(Array(ids.shuffled(using: &rng).prefix(2)), toWindow: open.randomElement(using: &rng)!)
                case 1 where !ids.isEmpty:
                    windows.openWindow(workspaces: [ids.randomElement(using: &rng)!])
                case 2 where !open.isEmpty:
                    windows.controller(for: open.randomElement(using: &rng)!)?.window?.close()
                case 3 where !live.isEmpty:
                    live.remove(at: Int.random(in: 0..<live.count, using: &rng))
                    Self.apply(services, keys: live)
                default:
                    live = Self.keys.filter { live.contains($0) || Bool.random(using: &rng) }
                    Self.apply(services, keys: live)
                }
                Self.expectConsistent(services, label)
            }
            #expect(windows.invariantViolations == 0)
            Self.closeAll(services)
        }
    }
}
