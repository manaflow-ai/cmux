import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

/// Verifies the lifted ``SplitDetachCoordinator/detachSurface(panelId:)`` drives
/// the host hooks and the ``SplitLayoutModel`` choreography in exactly the order
/// and under exactly the conditions the legacy `Workspace.detachSurface` body
/// did, over a synthetic fake host that records each call. The fake transfer
/// type stands in for the app target's `Workspace.DetachedSurfaceTransfer`.
@MainActor
struct SplitDetachCoordinatorTests {
    /// A minimal stand-in for the app-domain detached-surface transfer payload.
    struct FakeTransfer: Equatable {
        let panelId: UUID
        var isRemoteTerminal = false
        var hasRemoteCleanupConfiguration = false
    }

    /// Records every host call so a test can assert the exact effect sequence,
    /// and lets the test seed the close-tab result, the captured transfer, and
    /// the remote-accounting reads.
    final class FakeHost: SplitDetachHosting {
        typealias Transfer = FakeTransfer

        var workspaceId = UUID()
        var surfaceForPanel: [UUID: TabID] = [:]
        var ownedPanels: Set<UUID> = []
        var activeRemoteSurfaces: Set<UUID> = []
        var closeTabReturns = true
        var remoteCleanupApplied = false

        var calls: [String] = []

        func surfaceId(forPanelId panelId: UUID) -> TabID? { surfaceForPanel[panelId] }

        func captureDetachSource(panelId: UUID) -> Bool {
            guard ownedPanels.contains(panelId) else { return false }
            calls.append("captureDetachSource")
            return true
        }
        func publishCapturedDetachSource(transferCaptured: Bool) {
            calls.append("publish(\(transferCaptured ? "detach" : "detach_lost"))")
        }
        func discardCapturedDetachSource() { calls.append("discardCapturedDetachSource") }

        func closeTab(_ tabId: TabID) -> Bool {
            calls.append("closeTab(\(tabId.uuid.uuidString.prefix(4)))")
            return closeTabReturns
        }

        func insertForceCloseTabId(_ tabId: TabID) { calls.append("insertForceClose") }
        func removeForceCloseTabId(_ tabId: TabID) { calls.append("removeForceClose") }
        func isActiveRemoteTerminalSurface(_ panelId: UUID) -> Bool {
            activeRemoteSurfaces.contains(panelId)
        }
        var activeRemoteTerminalSurfaceCount: Int { activeRemoteSurfaces.count }
        func markSkipControlMasterCleanupAfterDetachedRemoteTransfer() {
            calls.append("markSkipControlMaster")
        }

        func isRemoteTerminal(_ transfer: FakeTransfer) -> Bool { transfer.isRemoteTerminal }
        func transferAdoptingRemoteCleanupConfigurationIfNeeded(_ transfer: FakeTransfer) -> FakeTransfer {
            calls.append("adoptCleanupConfig")
            guard !transfer.hasRemoteCleanupConfiguration else { return transfer }
            remoteCleanupApplied = true
            var copy = transfer
            copy.hasRemoteCleanupConfiguration = true
            return copy
        }
    }

    private func makeCoordinator(
        _ host: FakeHost,
        _ splitLayout: SplitLayoutModel<FakeTransfer>
    ) -> SplitDetachCoordinator<FakeTransfer> {
        let coordinator = SplitDetachCoordinator(splitLayout: splitLayout)
        coordinator.attach(host: host)
        return coordinator
    }

    @Test func detachCapturesTransferAndPublishesDetachInOrder() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        let tabId = TabID(uuid: surface)
        host.ownedPanels = [panel]
        host.surfaceForPanel = [panel: tabId]

        let splitLayout = SplitLayoutModel<FakeTransfer>()
        // The close pipeline stores the transfer; simulate it pre-seeded so
        // takeDetachedTransfer returns it (the fake host's closeTab does not run
        // the real delegate path).
        splitLayout.storeDetachedTransfer(FakeTransfer(panelId: panel), for: tabId)

        let result = makeCoordinator(host, splitLayout).detachSurface(panelId: panel)
        #expect(result == FakeTransfer(panelId: panel))
        #expect(host.calls == [
            "captureDetachSource",
            "insertForceClose",
            "closeTab(\(surface.uuidString.prefix(4)))",
            "publish(detach)",
        ])
        // The transfer was consumed out of the model.
        #expect(splitLayout.pendingDetachedSurfaces.isEmpty)
        // A successful detach leaves exactly one open/close transaction balanced.
        #expect(splitLayout.activeDetachCloseTransactions == 0)
        #expect(splitLayout.detachingTabIds.contains(tabId))
    }

    @Test func detachWithNoCapturedTransferPublishesDetachLost() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        host.ownedPanels = [panel]
        host.surfaceForPanel = [panel: TabID(uuid: surface)]

        let splitLayout = SplitLayoutModel<FakeTransfer>()
        // No transfer stored -> takeDetachedTransfer returns nil.
        let result = makeCoordinator(host, splitLayout).detachSurface(panelId: panel)
        #expect(result == nil)
        #expect(host.calls.last == "publish(detach_lost)")
    }

    @Test func detachFailsWhenSurfaceMissingWithoutTouchingTree() {
        let host = FakeHost()
        let splitLayout = SplitLayoutModel<FakeTransfer>()
        #expect(makeCoordinator(host, splitLayout).detachSurface(panelId: UUID()) == nil)
        #expect(host.calls.isEmpty)
    }

    @Test func detachFailsWhenSourcePanelMissingWithoutTouchingTree() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        host.surfaceForPanel = [panel: TabID(uuid: surface)]
        // panel not in ownedPanels -> captureDetachSource returns false.
        let splitLayout = SplitLayoutModel<FakeTransfer>()
        #expect(makeCoordinator(host, splitLayout).detachSurface(panelId: panel) == nil)
        #expect(host.calls.isEmpty)
    }

    @Test func detachRejectedCloseRollsBackMarkForceCloseAndCapture() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        let tabId = TabID(uuid: surface)
        host.ownedPanels = [panel]
        host.surfaceForPanel = [panel: tabId]
        host.closeTabReturns = false

        let splitLayout = SplitLayoutModel<FakeTransfer>()
        #expect(makeCoordinator(host, splitLayout).detachSurface(panelId: panel) == nil)
        #expect(host.calls == [
            "captureDetachSource",
            "insertForceClose",
            "closeTab(\(surface.uuidString.prefix(4)))",
            "removeForceClose",
            "discardCapturedDetachSource",
        ])
        // The mid-detach mark and any captured transfer are rolled back.
        #expect(splitLayout.detachingTabIds.isEmpty)
        #expect(splitLayout.pendingDetachedSurfaces.isEmpty)
        #expect(splitLayout.activeDetachCloseTransactions == 0)
    }

    @Test func detachOfLastRemoteTerminalMarksSkipAndAdoptsCleanupConfig() {
        let host = FakeHost()
        let panel = UUID(), surface = UUID()
        let tabId = TabID(uuid: surface)
        host.ownedPanels = [panel]
        host.surfaceForPanel = [panel: tabId]
        host.activeRemoteSurfaces = [panel]  // count == 1, contains(panel)

        let splitLayout = SplitLayoutModel<FakeTransfer>()
        splitLayout.storeDetachedTransfer(
            FakeTransfer(panelId: panel, isRemoteTerminal: true),
            for: tabId
        )

        let result = makeCoordinator(host, splitLayout).detachSurface(panelId: panel)
        #expect(host.calls.contains("markSkipControlMaster"))
        #expect(host.calls.contains("adoptCleanupConfig"))
        #expect(host.remoteCleanupApplied)
        #expect(result?.hasRemoteCleanupConfiguration == true)
    }

    @Test func detachOfNonLastRemoteTerminalDoesNotMarkSkip() {
        let host = FakeHost()
        let panel = UUID(), other = UUID(), surface = UUID()
        let tabId = TabID(uuid: surface)
        host.ownedPanels = [panel]
        host.surfaceForPanel = [panel: tabId]
        host.activeRemoteSurfaces = [panel, other]  // count == 2

        let splitLayout = SplitLayoutModel<FakeTransfer>()
        splitLayout.storeDetachedTransfer(
            FakeTransfer(panelId: panel, isRemoteTerminal: true),
            for: tabId
        )

        _ = makeCoordinator(host, splitLayout).detachSurface(panelId: panel)
        #expect(!host.calls.contains("markSkipControlMaster"))
        #expect(!host.calls.contains("adoptCleanupConfig"))
    }
}
