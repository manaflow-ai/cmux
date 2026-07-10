#if os(iOS)
import UIKit

final class TranscriptCollectionView: UICollectionView {
    #if DEBUG
    var allowsReloadData = true
    private(set) var reloadDataCallCount = 0
    #endif

    override func reloadData() {
        #if DEBUG
        reloadDataCallCount += 1
        if !allowsReloadData {
            assertionFailure("TranscriptListViewController must not call reloadData after initial mount")
        }
        #endif
        super.reloadData()
    }

    func updateAccessibilityOrder() {
        let coordinateView = superview ?? self
        accessibilityElements = visibleCells.sorted { lhs, rhs in
            lhs.convert(lhs.bounds, to: coordinateView).minY < rhs.convert(rhs.bounds, to: coordinateView).minY
        }
    }
}
#endif
