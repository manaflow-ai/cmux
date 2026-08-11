#if os(iOS)
import UIKit

extension TranscriptListViewController {
    var bottomRestOffset: CGPoint {
        let minimumY = -collectionView.contentInset.top
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.contentInset.bottom
        )
        return CGPoint(x: -collectionView.contentInset.left, y: pixelRounded(maximumY))
    }

    var isScrollInteractionActive: Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }
}
#endif
