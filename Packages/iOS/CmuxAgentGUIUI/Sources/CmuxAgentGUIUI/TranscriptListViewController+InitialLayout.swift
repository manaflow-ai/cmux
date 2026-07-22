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
        let seed = heightCache
        let batch = TranscriptInitialLayoutBatch(
            rows: rows,
            spacingByID: TranscriptRowSpacing.resolved(for: rows, density: density),
            width: width,
            density: density,
            scale: view.window?.screen.scale ?? traitCollection.displayScale,
            preferredContentSizeCategory: traitCollection.preferredContentSizeCategory
        )
        initialLayoutBatchCount += 1
        let measurement = Task.detached(priority: .userInitiated) {
            batch.measuredCache(seededBy: seed)
        }
        initialLayoutTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await measurement.value
            } onCancel: {
                measurement.cancel()
            }
            guard let self, self.initialLayoutGeneration == generation else { return }
            self.initialLayoutTask = nil
            guard !Task.isCancelled, let result else {
                self.rescheduleInitialLayoutIfNeeded()
                return
            }
            self.backgroundLayoutComputationCount += result.computationCount
            let currentRowsByID = Dictionary(uniqueKeysWithValues: self.currentRows.map { ($0.rowID, $0) })
            let currentSpacing = TranscriptRowSpacing.resolved(
                for: self.currentRows,
                density: self.currentDensity
            )
            if self.currentDensity == density,
               abs(self.collectionView.bounds.width - width) <= 0.5 {
                for (rowID, entry) in result.cache
                where currentRowsByID[rowID] == entry.row
                    && currentSpacing[rowID] == entry.spacing {
                    self.heightCache[rowID] = entry
                }
            }
            guard self.currentRows == rows,
                  self.currentDensity == density,
                  abs(self.collectionView.bounds.width - width) <= 0.5
            else {
                self.rescheduleInitialLayoutIfNeeded()
                return
            }
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
        }
    }

    func cancelInitialLayout() {
        initialLayoutGeneration &+= 1
        initialLayoutTask?.cancel()
        initialLayoutTask = nil
    }

    private func rescheduleInitialLayoutIfNeeded() {
        guard dataSource.snapshot().itemIdentifiers.isEmpty,
              currentRows.count >= 100,
              collectionView.bounds.width > 1
        else {
            return
        }
        scheduleInitialLayout(for: currentRows)
    }
}
#endif
