#if os(iOS)
import UIKit

final class TranscriptCollectionLayout: UICollectionViewLayout {
    var heightForItem: ((IndexPath, CGFloat) -> CGFloat)?

    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var contentSize = CGSize.zero
    private var measuredWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 0
    private var needsMeasurement = true

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        let height = collectionView.bounds.height
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let mustRebuild = needsMeasurement
            || abs(measuredWidth - width) > 0.5
            || abs(measuredHeight - height) > 0.5
            || attributes.count != itemCount
        guard mustRebuild else {
            return
        }
        measuredWidth = width
        measuredHeight = height
        needsMeasurement = false
        attributes.removeAll(keepingCapacity: true)
        attributes.reserveCapacity(itemCount)
        var originY: CGFloat = 0
        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let height = max(1, heightForItem?(indexPath, width) ?? 44)
            let itemAttributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            itemAttributes.frame = CGRect(x: 0, y: originY, width: width, height: height)
            attributes.append(itemAttributes)
            originY += height
        }
        contentSize = CGSize(width: width, height: max(originY, height))
    }

    override var collectionViewContentSize: CGSize {
        contentSize
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return true }
        return abs(collectionView.bounds.width - newBounds.width) > 0.5
            || abs(collectionView.bounds.height - newBounds.height) > 0.5
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        needsMeasurement = true
        super.invalidateLayout(with: context)
    }

    func invalidateMeasurements() {
        needsMeasurement = true
        invalidateLayout()
    }
}
#endif
