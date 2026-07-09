import Foundation
import Testing
@testable import CmuxPanes

/// Verifies the lifted ``SurfaceTeardownCoordinator`` drives the host teardown
/// hooks in exactly the order the legacy `Workspace.teardownAllPanels` body ran
/// them, over a synthetic fake host that records each call.
@MainActor
struct SurfaceTeardownCoordinatorTests {
    /// Records every host call so a test can assert the exact teardown sequence.
    final class FakeHost: SurfaceTeardownHosting {
        var workspaceId = UUID()
        var calls: [String] = []

        func disablePortalRendering() { calls.append("disablePortalRendering") }
        func surfaceTeardownClearLayoutFollowUp() { calls.append("clearLayoutFollowUp") }
        func hideAllTerminalPortalViews() { calls.append("hideAllTerminalPortalViews") }
        func hideAllBrowserPortalViews() { calls.append("hideAllBrowserPortalViews") }
        func discardAllPanelsForTeardown() { calls.append("discardAllPanelsForTeardown") }
        func pruneAllSurfaceMetadata() { calls.append("pruneAllSurfaceMetadata") }
        func syncRemotePortScanTTYs() { calls.append("syncRemotePortScanTTYs") }
        func recomputeListeningPorts() { calls.append("recomputeListeningPorts") }
        func surfaceTeardownClearRemoteConfigurationIfWorkspaceBecameLocal() {
            calls.append("clearRemoteConfigurationIfWorkspaceBecameLocal")
        }
        func clearPerPanelTeardownBookkeeping() { calls.append("clearPerPanelTeardownBookkeeping") }
    }

    @Test func teardownDrivesHooksInLegacyOrder() {
        let host = FakeHost()
        let coordinator = SurfaceTeardownCoordinator()
        coordinator.attach(host: host)

        coordinator.teardownAllPanels()

        // The exact statement order of the legacy `Workspace.teardownAllPanels`:
        // portal rendering off, layout follow-up cleared, both portal sets hidden,
        // every panel discarded, surface metadata pruned, remote port scan
        // re-synced, listening ports recomputed, remote config cleared if local,
        // then the per-panel bookkeeping dropped.
        #expect(host.calls == [
            "disablePortalRendering",
            "clearLayoutFollowUp",
            "hideAllTerminalPortalViews",
            "hideAllBrowserPortalViews",
            "discardAllPanelsForTeardown",
            "pruneAllSurfaceMetadata",
            "syncRemotePortScanTTYs",
            "recomputeListeningPorts",
            "clearRemoteConfigurationIfWorkspaceBecameLocal",
            "clearPerPanelTeardownBookkeeping",
        ])
    }

    @Test func teardownNoOpsWhenHostDeallocated() {
        let coordinator = SurfaceTeardownCoordinator()
        autoreleasepool {
            let host = FakeHost()
            coordinator.attach(host: host)
        }
        // Weak host is gone -> teardown touches nothing and does not crash.
        coordinator.teardownAllPanels()
    }
}
