#if canImport(UIKit)
#if DEBUG
import UIKit

/// DEBUG hooks for the recovery stress harness and the free-drain regression
/// test. Kept out of GhosttySurfaceView.swift so the debug surface does not
/// grow the main file; everything here drives the production recovery path.
/// DEBUG-only free-drain observation registry, keyed weakly per view. Lives
/// here (not as a stored property on GhosttySurfaceView) so the debug seam
/// adds no lines to the budget-capped base file.
extension GhosttySurfaceView {
    @MainActor
    // lint:allow namespace-enum — weak per-view DEBUG observer registry nested in the owning type; a stored property would grow the budget-capped base file.
    enum RecoveryStressObservers {
        private final class Entry {
            weak var view: GhosttySurfaceView?
            let observer: @MainActor @Sendable (GhosttySurfaceView.RecoveryStressSnapshot) -> Void
            init(view: GhosttySurfaceView, observer: @escaping @MainActor @Sendable (GhosttySurfaceView.RecoveryStressSnapshot) -> Void) {
                self.view = view
                self.observer = observer
            }
        }

        private static var entries: [ObjectIdentifier: Entry] = [:]

        static func set(
            _ observer: (@MainActor @Sendable (GhosttySurfaceView.RecoveryStressSnapshot) -> Void)?,
            for view: GhosttySurfaceView
        ) {
            entries = entries.filter { $0.value.view != nil }
            if let observer {
                entries[ObjectIdentifier(view)] = Entry(view: view, observer: observer)
            } else {
                entries.removeValue(forKey: ObjectIdentifier(view))
            }
        }

        static func notifyFreeDrain(_ view: GhosttySurfaceView) {
            guard let entry = entries[ObjectIdentifier(view)], entry.view === view else { return }
            entry.observer(view.recoveryStressSnapshot())
        }
    }
}

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
