#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

extension TranscriptListViewController {
    func captureAnchor(pinningExactBottomRest: Bool = false) -> TranscriptAnchorSnapshot? {
        let screenCoordinateView = view.window ?? view
        let viewportFrame = collectionView.convert(collectionView.bounds, to: screenCoordinateView).standardized
        let visibleAttributes = collectionView.collectionViewLayout
            .layoutAttributesForElements(in: collectionView.bounds) ?? []
        let candidates: [(rowID: TranscriptRowID, frame: CGRect, item: Int)] = visibleAttributes
            .compactMap { attributes in
                guard attributes.representedElementCategory == .cell,
                      let rowID = dataSource.itemIdentifier(for: attributes.indexPath)
                else {
                    return nil
                }
                let screenFrame = collectionView.convert(attributes.frame, to: screenCoordinateView).standardized
                return (
                    rowID,
                    screenFrame,
                    attributes.indexPath.item
                )
            }
        guard !candidates.isEmpty else { return nil }

        let selected: (rowID: TranscriptRowID, frame: CGRect, item: Int)
        if distanceFromBottom <= CGFloat(TranscriptMutationApplyPolicy.bottomStickinessThreshold) {
            selected = candidates.min { lhs, rhs in
                let lhsDistance = abs(lhs.frame.maxY - viewportFrame.maxY)
                let rhsDistance = abs(rhs.frame.maxY - viewportFrame.maxY)
                return lhsDistance == rhsDistance ? lhs.item < rhs.item : lhsDistance < rhsDistance
            }!
        } else {
            let fullyVisible = candidates.filter {
                $0.frame.minY >= viewportFrame.minY - 0.5
                    && $0.frame.maxY <= viewportFrame.maxY + 0.5
            }
            let selectionPool = fullyVisible.isEmpty ? candidates : fullyVisible
            guard let topmost = selectionPool.min(by: { lhs, rhs in
                lhs.frame.minY == rhs.frame.minY ? lhs.item < rhs.item : lhs.frame.minY < rhs.frame.minY
            }) else {
                return nil
            }
            selected = topmost
        }
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let pixelTolerance = 1 / max(scale, 1)
        return TranscriptAnchorSnapshot(
            rowID: selected.rowID,
            screenY: selected.frame.minY,
            pinsExactBottomRest: pinningExactBottomRest
                && abs(collectionView.contentOffset.y - bottomRestOffset.y) <= pixelTolerance
        )
    }

    func contentOffset(preservingTopOf anchor: TranscriptAnchorSnapshot) -> CGPoint? {
        guard let indexPath = dataSource.indexPath(for: anchor.rowID),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        else {
            return nil
        }
        let screenCoordinateView = view.window ?? view
        let currentScreenY = collectionView.convert(attributes.frame, to: screenCoordinateView).standardized.minY
        // The apply-time offset cancels out of this screen-space correction. The
        // selected row's actual post-layout top edge is the sole pin authority,
        // independent of which register contributed its surrounding spacing.
        // `contentOffset` already incorporates `adjustedContentInset`; adding the
        // inset again here would double-count the safe-area/nav contribution.
        let unalignedTargetY = collectionView.contentOffset.y
            + anchor.screenY
            - currentScreenY
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let anchorTargetY = (unalignedTargetY * max(scale, 1)).rounded() / max(scale, 1)
        let minimumY = bottomRestOffset.y
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.contentInset.bottom
        )
        let targetY = anchor.pinsExactBottomRest
            ? minimumY
            : min(max(anchorTargetY, minimumY), maximumY)
        return CGPoint(x: collectionView.contentOffset.x, y: targetY)
    }
}
#endif
