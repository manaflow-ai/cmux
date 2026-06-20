import Foundation
import Testing
import Bonsplit
@testable import CmuxPanes

/// Verifies the lifted ``SplitCloseCoordinator`` commands drive the host hooks
/// in exactly the order and under exactly the conditions the legacy `Workspace`
/// `requestCloseTab` / `requestCloseTabRecordingHistory` bodies did, over a
/// synthetic fake host that records each call.
@MainActor
struct SplitCloseCoordinatorTests {
    /// Records every host call so a test can assert the exact effect sequence.
    /// `closeTab` returns a configurable success; the bookkeeping hooks just
    /// append to ``calls``.
    final class FakeHost: SplitCloseHosting {
        var workspaceId = UUID()
        var panelForSurface: [TabID: UUID] = [:]
        var closeTabReturns = true

        var calls: [String] = []

        func panelId(forSurfaceId surfaceId: TabID) -> UUID? { panelForSurface[surfaceId] }
        func markCloseHistoryEligible(panelId: UUID) {
            calls.append("markCloseHistoryEligible(\(panelId.uuidString.prefix(4)))")
        }
        func insertForceCloseTabId(_ tabId: TabID) {
            calls.append("insertForceClose(\(tabId.uuid.uuidString.prefix(4)))")
        }
        func removeForceCloseTabId(_ tabId: TabID) {
            calls.append("removeForceClose(\(tabId.uuid.uuidString.prefix(4)))")
        }
        func closeTab(_ tabId: TabID) -> Bool {
            calls.append("closeTab(\(tabId.uuid.uuidString.prefix(4)))")
            return closeTabReturns
        }
    }

    private func makeCoordinator(_ host: FakeHost) -> SplitCloseCoordinator {
        let coordinator = SplitCloseCoordinator()
        coordinator.attach(host: host)
        return coordinator
    }

    // MARK: requestCloseTab

    @Test func forcedCloseInsertsBypassBeforeCloseAndKeepsItOnSuccess() {
        let host = FakeHost()
        let surface = UUID()
        let tab = TabID(uuid: surface)

        #expect(makeCoordinator(host).requestCloseTab(tab, force: true))
        // Insert the bypass, then close; no rollback when the close took.
        #expect(host.calls == [
            "insertForceClose(\(surface.uuidString.prefix(4)))",
            "closeTab(\(surface.uuidString.prefix(4)))",
        ])
    }

    @Test func forcedCloseRollsBackBypassWhenCloseRejected() {
        let host = FakeHost()
        host.closeTabReturns = false
        let surface = UUID()
        let tab = TabID(uuid: surface)

        #expect(makeCoordinator(host).requestCloseTab(tab, force: true) == false)
        #expect(host.calls == [
            "insertForceClose(\(surface.uuidString.prefix(4)))",
            "closeTab(\(surface.uuidString.prefix(4)))",
            "removeForceClose(\(surface.uuidString.prefix(4)))",
        ])
    }

    @Test func nonForcedCloseTouchesNoBypassSet() {
        let host = FakeHost()
        let surface = UUID()
        let tab = TabID(uuid: surface)

        #expect(makeCoordinator(host).requestCloseTab(tab, force: false))
        #expect(host.calls == ["closeTab(\(surface.uuidString.prefix(4)))"])

        // A rejected non-forced close still touches no bypass set.
        let rejected = FakeHost()
        rejected.closeTabReturns = false
        #expect(makeCoordinator(rejected).requestCloseTab(tab, force: false) == false)
        #expect(rejected.calls == ["closeTab(\(surface.uuidString.prefix(4)))"])
    }

    // MARK: requestCloseTabRecordingHistory

    @Test func recordingHistoryMarksEligiblePanelThenCloses() {
        let host = FakeHost()
        let surface = UUID(), panel = UUID()
        let tab = TabID(uuid: surface)
        host.panelForSurface = [tab: panel]

        #expect(makeCoordinator(host).requestCloseTabRecordingHistory(tab, force: true))
        #expect(host.calls == [
            "markCloseHistoryEligible(\(panel.uuidString.prefix(4)))",
            "insertForceClose(\(surface.uuidString.prefix(4)))",
            "closeTab(\(surface.uuidString.prefix(4)))",
        ])
    }

    @Test func recordingHistorySkipsMarkWhenPanelUnresolved() {
        let host = FakeHost()
        let surface = UUID()
        let tab = TabID(uuid: surface)
        // No panelForSurface mapping -> no markCloseHistoryEligible call.

        #expect(makeCoordinator(host).requestCloseTabRecordingHistory(tab, force: false))
        #expect(host.calls == ["closeTab(\(surface.uuidString.prefix(4)))"])
    }

    // MARK: detached host

    @Test func commandsNoOpWhenHostDeallocated() {
        let coordinator = SplitCloseCoordinator()
        autoreleasepool {
            let host = FakeHost()
            coordinator.attach(host: host)
        }
        // Weak host is gone -> commands report failure and touch nothing.
        #expect(coordinator.requestCloseTab(TabID(uuid: UUID()), force: true) == false)
        #expect(coordinator.requestCloseTabRecordingHistory(TabID(uuid: UUID()), force: true) == false)
    }
}
