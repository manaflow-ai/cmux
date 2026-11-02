import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextControl
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextLayout
import CmuxNextSidebar
import Foundation
import Testing

/// Reads the actual commands emitted by production pending placement, then
/// checks the scripted daemon's persisted order after its personal events.
@MainActor @Suite(.serialized)
struct PlacementWriteOrderTests {
    private nonisolated struct Seed: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "gallery-seed-burst"
    }
    private nonisolated struct Report: DaemonRequest {
        typealias Response = PlacementGalleryCaptured
        static let command = "gallery-report"
    }

    private static func burst(mixed: Bool, mode: String = "") async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let bridge = DaemonBridge.fakePython(["-c", PlacementStaleRowsGalleryTests.daemonScript, mixed ? "1" : "0", mode])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-placement-order-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            let identity = try await connection.start()
            services.daemon.start(first: { .success((connection, identity)) }, makeConnection: { connection })
            defer { services.daemon.shutdownConnection() }
            try await PlacementStaleRowsGalleryTests.waitForInitialSnapshot(services)
            let windows = services.windows
            windows.ordersWindowsIn = false
            let controller = try #require(windows.openWindow(workspaces: ["k1"]))
            defer { controller.teardown(); controller.window?.close() }
            for id in ["k2", "k3", "k4"] {
                NewWorkspacePlacements.expect(id, in: controller.state.id, slot: .bottom(anchor: nil), byDefault: nil, windows: windows)
            }
            _ = try await connection.request(Seed())
            let snapshot = try await connection.snapshot()
            let scope = DaemonCommandScope()
            defer { scope.close() }
            services.daemon.store.apply(snapshot: snapshot.tree)
            windows.registry.apply { $0.openWindow(id: controller.state.id, workspaceIDs: ["k4", "k3", "k2", "k1"]); return WindowRegistry.Changes() }
            DaemonCommandScope.$current.withValue(scope) { windows.applyPendingPlacements(live: ["k1", "k2", "k3", "k4"]) }
            #expect(scope.ticketCount >= 3, "queued writes keep the action's scope open")
            #expect(controller.sidebar.model.selectableWorkspaces.map(\.id.rawValue) == ["k1", "k2", "k3", "k4"])
            if mode == "closed" { windows.registry.apply { $0.setRestored(controller.state.id, open: false); return WindowRegistry.Changes() } }
            try await ControlDeadline.shared.run(method: "placement burst", deadline: .now + .seconds(15)) {
                await scope.waitUntilIdle()
            }
            #expect(scope.isIdle)
            if mode == "disconnect" {
                #expect(!scope.failures.isEmpty)
            } else {
                let captured = try await connection.request(Report())
                if mode.isEmpty {
                    #expect(scope.failures.isEmpty)
                    #expect(captured.order == ["k1", "k2", "k3", "k4"])
                    #expect(captured.writes.map(\.workspace_key) == ["k2", "k3", "k4"])
                    #expect(captured.writes.map(\.index) == [3, 3, 3])
                } else if mode == "closed" {
                    // Every placement skips its closed window; a skip is not a failure.
                    #expect(scope.failures.isEmpty)
                    #expect(captured.order == ["k4", "k3", "k2", "k1"])
                    #expect(captured.attempts == 0)
                } else {
                    #expect(!scope.failures.isEmpty)
                    #expect(captured.order == ["k4", "k3", "k2", "k1"])
                    #expect(captured.attempts == 1, "dependent writes stop after the first failure")
                }
            }
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func aBurstPersistsTheSameOrderItsOptimisticRowsShow(mixed: Bool) async throws {
        try await Self.burst(mixed: mixed)
    }

    @Test(arguments: ["fail", "disconnect", "closed"])
    func failedOrAbandonedPlacementReleasesTheQueuedCommands(mode: String) async throws {
        try await Self.burst(mixed: false, mode: mode)
    }

    /// A placement that skips (its window closed, its workspace deleted
    /// before its turn) lets the ones queued after it run; a failed write
    /// stops them. Each one that did not apply settles its pending edit once.
    @Test(arguments: [PersonalPlacementQueue.Outcome.skipped, .failed])
    func onlyAFailedPlacementStopsTheOnesQueuedAfterIt(first: PersonalPlacementQueue.Outcome) async {
        @MainActor final class Log { var ran: [String] = [], settled: [String] = [] }
        let queue = PersonalPlacementQueue(), home = DaemonService(), scope = DaemonCommandScope(), log = Log()
        DaemonCommandScope.$current.withValue(scope) {
            let order: [(String, PersonalPlacementQueue.Outcome)] = [("k2", first), ("k3", .applied), ("k4", .applied)]
            for (id, outcome) in order {
                queue.enqueue(on: home, failed: { log.settled.append(id) }) { log.ran.append(id); return outcome }
            }
        }
        await scope.waitUntilIdle()
        if first == .skipped {
            #expect(log.ran == ["k2", "k3", "k4"])
            #expect(log.settled == ["k2"])
            #expect(scope.failures.isEmpty)
        } else {
            #expect(log.ran == ["k2"])
            #expect(log.settled == ["k2", "k3", "k4"])
            #expect(scope.failures.count == 3)
        }
    }
}
