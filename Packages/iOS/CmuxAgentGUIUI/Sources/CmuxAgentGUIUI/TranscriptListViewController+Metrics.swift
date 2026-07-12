#if os(iOS)
public import UIKit

extension TranscriptListViewController {
    /// The current physical bottom obstruction reported by `keyboardLayoutGuide`.
    public var keyboardBottomInset: CGFloat {
        guard isViewLoaded else { return 0 }
        let obstruction = view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY
        return pixelRounded(max(0, obstruction - view.safeAreaInsets.bottom))
    }

    var bottomRestOffset: CGPoint {
        CGPoint(x: -collectionView.contentInset.left, y: -collectionView.contentInset.top)
    }

    var isScrollInteractionActive: Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }
}
#endif
