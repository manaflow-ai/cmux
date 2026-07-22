#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

extension TranscriptListViewController {
    func scheduleInitialLayout(for rows: [TranscriptRow]) {
        cancelInitialLayout()
        initialLayoutGeneration &+= 1
        let generation = initialLayoutGeneration
        let width = collectionView.bounds.width
        let density = currentDensity
        let batch = TranscriptInitialLayoutBatch(
            rows: rows,
            spacingByID: TranscriptRowSpacing.resolved(for: rows, density: density),
            width: width,
            density: density,
            scale: view.window?.screen.scale ?? traitCollection.displayScale,
            preferredContentSizeCategory: traitCollection.preferredContentSizeCategory
        )
        let measurement = Task.detached(priority: .userInitiated) {
            batch.measuredCache()
        }
        initialLayoutTask = Task { [weak self] in
            let cache = await withTaskCancellationHandler {
                await measurement.value
            } onCancel: {
                measurement.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  let cache,
                  self.initialLayoutGeneration == generation,
                  self.currentRows == rows,
                  self.currentDensity == density,
                  abs(self.collectionView.bounds.width - width) <= 0.5
            else {
                return
            }
            self.heightCache = cache
            self.backgroundLayoutComputationCount += cache.count
            let inserted = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
                (row.rowID, index)
            })
            self.applyRows(
                rows,
                diff: TranscriptProjectionDiff(
                    inserted: inserted,
                    removed: [:],
                    moved: [:],
                    updated: []
                )
            )
            self.initialLayoutTask = nil
        }
    }

    func cancelInitialLayout() {
        initialLayoutGeneration &+= 1
        initialLayoutTask?.cancel()
        initialLayoutTask = nil
    }
}
#endif
