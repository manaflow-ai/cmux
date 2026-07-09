#if canImport(UIKit)
#if DEBUG
import UIKit

/// DEBUG hooks for the recovery stress harness and the free-drain regression
/// test. Kept out of GhosttySurfaceView.swift so the debug surface does not
/// grow the main file; everything here drives the production recovery path.
extension GhosttySurfaceView {
    struct RecoveryStressSnapshot: Equatable, Sendable {
        let generation: UInt64
        let pendingSurfaceFreeCount: Int
        let hasSurface: Bool
        let recoveryPaused: Bool
    }

    func recoveryStressSnapshot() -> RecoveryStressSnapshot {
        RecoveryStressSnapshot(
            generation: surfaceGeneration,
            pendingSurfaceFreeCount: pendingSurfaceFreeCount,
            hasSurface: surface != nil,
            recoveryPaused: renderPipelineRecoveryPaused
        )
    }

    @discardableResult
    func forceRecoveryForStress() -> RecoveryStressSnapshot {
        _ = recoverRenderPipeline(
            reason: "recovery_stress",
            stalledMs: 0,
            replay: .delegateWhenNoCaller
        )
        return recoveryStressSnapshot()
    }
}
#endif
#endif
