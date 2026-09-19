#if canImport(UIKit)
import CmuxMobileTerminal
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI

/// `dismantleUIView` runs while SwiftUI is tearing down the owning view
/// graph, so the surface's synchronous artifact-count reset must not
/// re-enter that graph through the SwiftUI-facing callbacks: writing the
/// dying graph's `@State` mid-teardown trips Swift's exclusivity
/// enforcement (Sentry CMUXTERM-MACOS-2Z6D). These tests pin the gating
/// contract — no SwiftUI-facing notification during dismantle, while a
/// live (transient window detach) reset keeps notifying — not the
/// exclusivity abort itself.
@Suite("Ghostty surface coordinator teardown", .serialized)
struct GhosttySurfaceCoordinatorTeardownTests {
    @MainActor
    private final class ArtifactCallbackRecorder {
        var reportedCounts: [Int] = []
        var galleryRefreshSignals = 0
    }

    @MainActor
    private func makeCoordinator(
        store: MobileShellComposite,
        recorder: ArtifactCallbackRecorder
    ) -> GhosttySurfaceRepresentable.Coordinator {
        GhosttySurfaceRepresentable.Coordinator(
            workspaceID: "workspace",
            surfaceID: "teardown-surface",
            store: store,
            artifactFilesEnabled: true,
            terminalFolderTapEnabled: false,
            terminalFilesChipEnabled: true,
            sessionArtifactCountEnabled: false,
            visibleArtifactCount: 0,
            onArtifactFilesRequested: { _ in },
            onArtifactPathTapped: { _ in },
            onVisibleArtifactCountChanged: { recorder.reportedCounts.append($0) },
            onArtifactGalleryRefreshSignal: { _ in recorder.galleryRefreshSignals += 1 }
        )
    }

    @MainActor
    @Test("dismantle does not notify the SwiftUI view graph")
    func dismantleDoesNotNotifyTheSwiftUIViewGraph() async throws {
        let store = MobileShellComposite.preview()
        let recorder = ArtifactCallbackRecorder()
        let coordinator = makeCoordinator(store: store, recorder: recorder)
        let surfaceView = GhosttySurfaceView(
            runtime: try GhosttyRuntime.shared(),
            delegate: coordinator
        )
        coordinator.attach(surfaceView: surfaceView)
        // Seed a nonzero count so the dismantle-time reset has a 3 -> 0
        // transition it would otherwise report.
        coordinator.ghosttySurfaceView(surfaceView, didChangeVisibleArtifactCount: 3)
        #expect(recorder.reportedCounts == [3])
        recorder.reportedCounts.removeAll()

        let hostView = GhosttySurfaceHostView(
            surfaceView: surfaceView,
            keyboardFrameTracker: coordinator.fallbackKeyboardFrameTracker
        )
        GhosttySurfaceRepresentable.dismantleUIView(hostView, coordinator: coordinator)

        // Coordinator-internal bookkeeping still resets with the surface...
        #expect(coordinator.visibleArtifactCount == 0)
        #expect(coordinator.artifactCountNeedsRefresh)
        // ...but the dying view graph is never re-entered.
        #expect(recorder.reportedCounts.isEmpty)
        #expect(recorder.galleryRefreshSignals == 0)
    }

    @MainActor
    @Test("a live reset still notifies the view graph")
    func liveResetStillNotifiesTheViewGraph() async throws {
        let store = MobileShellComposite.preview()
        let recorder = ArtifactCallbackRecorder()
        let coordinator = makeCoordinator(store: store, recorder: recorder)
        let surfaceView = GhosttySurfaceView(
            runtime: try GhosttyRuntime.shared(),
            delegate: coordinator
        )
        defer {
            coordinator.detach()
            surfaceView.prepareForDismantle()
        }
        coordinator.attach(surfaceView: surfaceView)
        coordinator.ghosttySurfaceView(surfaceView, didChangeVisibleArtifactCount: 3)
        #expect(recorder.reportedCounts == [3])
        recorder.reportedCounts.removeAll()

        // A transient window detach (didMoveToWindow(nil)) resets through the
        // same delegate callback while the view graph stays alive; that reset
        // must keep propagating so the chip and gallery drop their counts.
        coordinator.ghosttySurfaceViewDidResetArtifactCount(surfaceView)

        #expect(coordinator.visibleArtifactCount == 0)
        #expect(recorder.reportedCounts == [0])
        #expect(recorder.galleryRefreshSignals == 1)
    }
}
#endif
