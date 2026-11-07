import CmuxTerminalSharing
import CmuxTerminalSizing
import CoreGraphics
import Foundation
import Testing

@Suite struct TerminalSizingOverlayLifecycleTests {
    private let grid = TerminalGridSize(cols: 72, rows: 58)

    private func snapshot(
        generation: UInt64 = 1,
        isCloud: Bool = false,
        detachment: TerminalSharingDetachment? = nil
    ) -> TerminalSharingSnapshot {
        let state = TerminalSizingState(
            generation: generation,
            cols: grid.cols,
            rows: grid.rows,
            reason: .fixed,
            owners: ["mac:1"],
            policy: TerminalSizingPolicy(mode: .fixed, fixed: grid),
            participants: [TerminalSizingParticipantState(
                participant: TerminalSizingParticipant(
                    id: "mac:1",
                    userID: "u1",
                    deviceKind: .mac,
                    viewport: TerminalGridSize(cols: 118, rows: 76)
                ),
                counts: true
            )]
        )
        return TerminalSharingSnapshot(
            state: state,
            selfParticipantID: "mac:1",
            detachment: detachment,
            isCloud: isCloud
        )
    }

    private var geometry: TerminalSizeBoundsGeometry {
        TerminalSizeBoundsGeometry(
            paneSize: CGSize(width: 118 * 8, height: 76 * 16),
            surfacePixelSize: CGSize(width: 72 * 16, height: 58 * 32),
            cellPixelSize: CGSize(width: 16, height: 32),
            scale: 2,
            grid: grid
        )
    }

    @Test func localBoundsOnlyShowDuringAnInteraction() {
        var lifecycle = TerminalSizingOverlayLifecycle()
        #expect(lifecycle.update(snapshot: snapshot()))
        #expect(!lifecycle.updateGeometry(geometry, revision: 1, snapshotGeneration: 1))
        #expect(!lifecycle.isVisible)
        #expect(!lifecycle.showsBounds)

        #expect(!lifecycle.beginInteraction())
        #expect(lifecycle.updateGeometry(geometry, revision: 2, snapshotGeneration: 1))
        #expect(lifecycle.isVisible)
        #expect(lifecycle.showsBounds)
        #expect(lifecycle.endInteraction())
        #expect(!lifecycle.isVisible)
        #expect(!lifecycle.showsBounds)
    }

    @Test func repeatedGeometryDoesNotRedrawOrChangeAuthority() {
        var lifecycle = TerminalSizingOverlayLifecycle()
        lifecycle.update(snapshot: snapshot())
        lifecycle.beginInteraction()
        #expect(lifecycle.updateGeometry(geometry, revision: 4, snapshotGeneration: 1))
        #expect(!lifecycle.updateGeometry(geometry, revision: 4, snapshotGeneration: 1))
        #expect(!lifecycle.updateGeometry(geometry, revision: 3, snapshotGeneration: 1))
        #expect(lifecycle.geometry == geometry)
        #expect(lifecycle.isVisible)
    }

    @Test func newerGeometryUpdatesAnAlreadyVisibleProjection() {
        var lifecycle = TerminalSizingOverlayLifecycle(presentation: .persistent)
        lifecycle.update(snapshot: snapshot(isCloud: true))
        #expect(lifecycle.updateGeometry(geometry, revision: 1, snapshotGeneration: 1))
        var next = geometry
        next.hiddenColumns = 2
        #expect(lifecycle.updateGeometry(next, revision: 2, snapshotGeneration: 1))
        #expect(lifecycle.geometry == next)
        #expect(lifecycle.isVisible)
    }

    @Test func staleSnapshotCannotReplaceTheCurrentGrid() {
        var lifecycle = TerminalSizingOverlayLifecycle()
        let current = snapshot(generation: 9)
        lifecycle.update(snapshot: current)
        let accepted = lifecycle.update(snapshot: snapshot(generation: 10))
        #expect(accepted)
        #expect(lifecycle.snapshot?.state.generation == 10)
        #expect(!lifecycle.update(snapshot: snapshot(generation: 8)))
        #expect(lifecycle.snapshot?.state.generation == 10)
    }

    @Test func geometryFromAnOlderSnapshotCannotRedrawTheCurrentOne() {
        var lifecycle = TerminalSizingOverlayLifecycle()
        lifecycle.update(snapshot: snapshot(generation: 2))
        lifecycle.beginInteraction()
        #expect(lifecycle.updateGeometry(geometry, revision: 8, snapshotGeneration: 2))
        lifecycle.update(snapshot: snapshot(generation: 3))
        #expect(!lifecycle.updateGeometry(geometry, revision: 9, snapshotGeneration: 2))
        #expect(lifecycle.geometry == nil)
        #expect(!lifecycle.updateGeometry(geometry, revision: 1, snapshotGeneration: 3))
    }

    @Test(arguments: [
        TerminalSizingOverlayLifecycleTests.Interruption.focusLoss,
        .cancellation,
        .hiddenSurface,
    ])
    func interruptionClearsAndDoesNotResurrectLocalBounds(_ interruption: Interruption) {
        var lifecycle = TerminalSizingOverlayLifecycle()
        lifecycle.update(snapshot: snapshot())
        lifecycle.beginInteraction()
        lifecycle.updateGeometry(geometry, revision: 1, snapshotGeneration: 1)
        #expect(lifecycle.isVisible)

        switch interruption {
        case .focusLoss:
            lifecycle.focusLost()
            lifecycle.focusGained()
        case .cancellation:
            lifecycle.cancelInteraction()
        case .hiddenSurface:
            lifecycle.surfaceVisibilityChanged(false)
            lifecycle.surfaceVisibilityChanged(true)
        }

        #expect(!lifecycle.isVisible)
        #expect(!lifecycle.showsBounds)
        lifecycle.beginInteraction()
        #expect(!lifecycle.isVisible)
        #expect(lifecycle.updateGeometry(geometry, revision: 2, snapshotGeneration: 1))
        #expect(lifecycle.isVisible)
    }

    @Test func persistentCloudProjectionSurvivesFocusGainWithoutAResizeGesture() {
        var lifecycle = TerminalSizingOverlayLifecycle(presentation: .persistent)
        lifecycle.update(snapshot: snapshot(isCloud: true))
        lifecycle.updateGeometry(geometry, revision: 1, snapshotGeneration: 1)
        #expect(lifecycle.isVisible)
        lifecycle.focusLost()
        #expect(!lifecycle.isVisible)
        lifecycle.focusGained()
        #expect(lifecycle.isVisible)
        lifecycle.surfaceVisibilityChanged(false)
        #expect(!lifecycle.isVisible)
        lifecycle.surfaceVisibilityChanged(true)
        #expect(lifecycle.isVisible)
    }

    @Test func detachedCardIsIndependentFromTransientBounds() {
        let detachment = TerminalSharingDetachment(reason: .hostShutdown, at: Date(timeIntervalSince1970: 1))
        var lifecycle = TerminalSizingOverlayLifecycle()
        lifecycle.update(snapshot: snapshot(detachment: detachment))
        #expect(lifecycle.isVisible)
        #expect(!lifecycle.showsBounds)
        lifecycle.surfaceVisibilityChanged(false)
        #expect(!lifecycle.isVisible)
    }

    private enum Interruption: CaseIterable, Sendable {
        case focusLoss
        case cancellation
        case hiddenSurface
    }
}
