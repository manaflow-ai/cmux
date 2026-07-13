#if os(iOS)
import CmuxAgentGUIProjection
public import UIKit

extension TranscriptListViewController {
    /// Reconfigures every transcript row for a new density while preserving the visible anchor.
    /// - Parameter density: The spacing and metadata-type register to apply.
    public func setDensity(_ density: TranscriptDensity) {
        if density == currentDensity {
            pendingDensity = nil
            return
        }
        guard isViewLoaded else {
            currentDensity = density
            return
        }
        guard !isScrollInteractionActive else {
            pendingDensity = density
            return
        }
        applyDensity(density)
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            applyPendingDensityIfPossible()
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        applyPendingDensityIfPossible()
    }

    private func applyDensity(_ density: TranscriptDensity) {
        cancelActiveScrollTransition()
        let anchor = captureAnchor(pinningExactBottomRest: true)
        currentDensity = density
        pendingDensity = nil
        guard !currentRows.isEmpty else { return }
        isApplyingDensityTransaction = true
        defer { isApplyingDensityTransaction = false }
        let snapshot = dataSource.snapshot()
        applySnapshot(
            snapshot,
            reconfiguring: Set(snapshot.itemIdentifiers),
            anchor: anchor,
            invalidatingLayout: true
        )
        (collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
        updateUnreadCountFromVisibility()
        updatePillVisibility()
    }

    func applySnapshot(
        _ snapshot: NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>,
        reconfiguring requestedIDs: Set<TranscriptRowID>,
        anchor: TranscriptAnchorSnapshot?,
        invalidatingLayout: Bool
    ) {
        let previousSpacing = spacingByID
        rowsByID = Dictionary(uniqueKeysWithValues: currentRows.map { ($0.rowID, $0) })
        spacingByID = TranscriptRowSpacing.resolved(for: currentRows, density: currentDensity)
        let currentSnapshot = dataSource.snapshot()
        let currentIDs = Set(currentSnapshot.itemIdentifiers)
        let retainedIDs = currentIDs.intersection(snapshot.itemIdentifiers)
        let spacingChangedIDs = retainedIDs.filter {
            previousSpacing[$0] != spacingByID[$0]
        }
        let reconfiguredIDs = requestedIDs.intersection(retainedIDs).union(spacingChangedIDs)
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if currentSnapshot.sectionIdentifiers != snapshot.sectionIdentifiers
                || currentSnapshot.itemIdentifiers != snapshot.itemIdentifiers {
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
            for rowID in reconfiguredIDs {
                guard let indexPath = self.dataSource.indexPath(for: rowID) else {
                    continue
                }
                if let cell = self.collectionView.cellForItem(at: indexPath) as? TranscriptCollectionCell {
                    _ = self.configure(cell: cell, rowID: rowID)
                }
            }
            if invalidatingLayout {
                // TODO(perf slice): invalidate only dirty rows plus spacing-dependent
                // neighbors; the current measurement reset is O(N) in transcript rows.
                (self.collectionView.collectionViewLayout as? TranscriptCollectionLayout)?
                    .invalidateMeasurements()
                self.collectionView.layoutIfNeeded()
            }
            if let anchor,
               let targetOffset = self.contentOffset(preservingTopOf: anchor) {
                self.collectionView.setContentOffset(targetOffset, animated: false)
            }
            CATransaction.commit()
        }
        #if DEBUG
        (collectionView as? TranscriptCollectionView)?.assertRestingRhythmTokens()
        #endif
    }

    private func applyPendingDensityIfPossible() {
        guard !isScrollInteractionActive, let pendingDensity else { return }
        applyDensity(pendingDensity)
    }
}
#endif
