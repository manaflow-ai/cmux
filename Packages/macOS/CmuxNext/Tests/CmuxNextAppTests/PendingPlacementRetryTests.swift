import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Coverage for the two deferred-placement edges introduced by cold Cmd-N:
/// a workspace can disappear after its placement was retained, and a callback
/// can enqueue an already-live placement while the rows pass is in progress.
@MainActor @Suite(.serialized)
struct PendingPlacementRetryTests {
    private static func services() throws -> (AppServices, WindowController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["base"], personal: ["base"]))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: ["base"]))
        controller.sidebar.resync()
        return (services, controller)
    }

    @Test(arguments: [false, true])
    func retainedPlacementIsRemovedWhenItsWorkspaceCloses(hasOwnerWithoutController: Bool) throws {
        let (services, controller) = try Self.services()
        defer { controller.teardown(); controller.window?.close() }
        let windows = services.windows
        let store = services.machines.local.store
        let id = "closed-before-placement"

        // It was reported once, but has not acquired an owner/controller yet.
        let owner: String? = hasOwnerWithoutController ? "controller-not-realized" : nil
        if let owner {
            windows.registry.apply { $0.openWindow(id: owner, workspaceIDs: [id]); return WindowRegistry.Changes() }
        }
        NewWorkspacePlacements.expect(id, in: owner, slot: .bottom(anchor: nil), byDefault: nil, windows: windows)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["base", id], personal: ["base", id]))
        windows.applyPendingPlacements(live: ["base", id])
        #expect(windows.pendingPlacements[id] != nil, "an ownerless live workspace remains deferred")

        // The daemon's next list omits it: this is a close, not a create still in flight.
        store.apply(snapshot: PlacementStaleRowsTests.tree(["base"], personal: ["base"]))
        windows.applyPendingPlacements(live: ["base"])
        #expect(windows.pendingPlacements[id] == nil)
        #expect(!windows.pendingPlacementOrder.contains(id))
    }

    @Test func placementWaitingForUnreportedOrProvisionalWorkspaceIsKept() throws {
        let (services, controller) = try Self.services()
        defer { controller.teardown(); controller.window?.close() }
        let windows = services.windows
        let store = services.machines.local.store
        let unreported = "not-yet-reported"
        NewWorkspacePlacements.expect(unreported, in: nil, slot: .bottom(anchor: nil), byDefault: nil, windows: windows)
        windows.applyPendingPlacements(live: [])
        #expect(windows.pendingPlacements[unreported] != nil)

        let key = WorkspaceKey.generate()
        let tab = ProvisionalTab().conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "test", hostName: nil)))
        store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: "provisional", tab: tab), index: nil),
                     transaction: .generate())
        NewWorkspacePlacements.expect(key.rawValue, in: nil, slot: .bottom(anchor: nil), byDefault: nil, windows: windows)
        windows.applyPendingPlacements(live: [])
        #expect(windows.pendingPlacements[key.rawValue] != nil)
    }

    private final class Callbacks {
        var first = 0
        var second = 0
    }

    @Test func callbackEnqueuingLivePlacementGetsOneFollowupPass() throws {
        let (services, controller) = try Self.services()
        defer { controller.teardown(); controller.window?.close() }
        let windows = services.windows
        let store = services.machines.local.store
        let first = "first-placement"
        let second = "second-placement"
        let callbacks = Callbacks()

        NewWorkspacePlacements.expect(first, in: controller.state.id, slot: nil, byDefault: nil,
                                      then: { _, _ in
                                          callbacks.first += 1
                                          NewWorkspacePlacements.expect(second, in: controller.state.id, slot: nil, byDefault: nil,
                                                                     then: { _, _ in callbacks.second += 1 }, windows: windows)
                                      }, windows: windows)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["base", first, second], personal: ["base", first, second]))
        windows.registry.apply { $0.openWindow(id: controller.state.id, workspaceIDs: ["base", first, second]); return WindowRegistry.Changes() }
        windows.applyPendingPlacements(live: ["base", first, second])

        #expect(callbacks.first == 1)
        #expect(callbacks.second == 1, "a placement registered by `then` was retried after the outer pass")
        #expect(windows.pendingPlacements.isEmpty)
        #expect(windows.pendingPlacementOrder.isEmpty)
    }
}
