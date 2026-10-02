#if canImport(UIKit)
import UIKit

@MainActor
protocol ConversationTranscriptLayoutDataSource: AnyObject {
    func transcriptItemCount() -> Int
    func transcriptHeight(at index: Int, width: CGFloat) -> CGFloat
    /// Vertical gap above item `index`.
    func transcriptSpacing(before index: Int) -> CGFloat
    func transcriptAppearance(at index: Int) -> ConversationTranscriptLayout.Appearance
}

/// A single-column, bottom-anchored transcript layout. Content shorter than
/// the viewport sits at the bottom, like Messages. Frames are computed from
/// cached heights, so a full pass over thousands of rows is a sum.
final class ConversationTranscriptLayout: UICollectionViewLayout {
    enum Appearance {
        case none
        /// New incoming bubble: grows from its tail corner.
        case incoming
        /// Outgoing bubble placed by the send animation; the cell is hidden meanwhile.
        case sent
        /// Plain fade (typing indicator removal, loading row).
        case fade
    }

    weak var dataSource: (any ConversationTranscriptLayoutDataSource)?
    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private var cachedAttributes: [UICollectionViewLayoutAttributes] = []
    var topPadding: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView, let dataSource else { return }
        let width = collectionView.bounds.width
        let count = dataSource.transcriptItemCount()
        frames.removeAll(keepingCapacity: true)
        frames.reserveCapacity(count)
        var y: CGFloat = topPadding
        for index in 0..<count {
            y += index == 0 ? 0 : dataSource.transcriptSpacing(before: index)
            let height = dataSource.transcriptHeight(at: index, width: width)
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        contentHeight = y + 6
        // Bottom-anchor short transcripts.
        let visible = collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
        if contentHeight < visible {
            let shift = visible - contentHeight
            for index in frames.indices { frames[index].origin.y += shift }
            contentHeight = visible
        }
        cachedAttributes = frames.enumerated().map { index, frame in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = frame
            return attributes
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !frames.isEmpty else { return [] }
        // Binary search the first frame intersecting rect.
        var low = 0, high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var index = low
        while index < frames.count, frames[index].minY <= rect.maxY {
            result.append(cachedAttributes[index])
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < cachedAttributes.count else { return nil }
        return cachedAttributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width || newBounds.height != collectionView?.bounds.height
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attributes = layoutAttributesForItem(at: itemIndexPath)?.copy() as? UICollectionViewLayoutAttributes else { return nil }
        switch dataSource?.transcriptAppearance(at: itemIndexPath.item) ?? .none {
        case .none:
            return attributes
        case .incoming:
            // Pop in from the leading bottom corner.
            let scale: CGFloat = 0.6
            attributes.transform = CGAffineTransform(translationX: -attributes.frame.width * (1 - scale) / 2, y: attributes.frame.height * (1 - scale) / 2)
                .scaledBy(x: scale, y: scale)
            attributes.alpha = 0
        case .sent:
            attributes.alpha = 0
        case .fade:
            attributes.alpha = 0
        }
        return attributes
    }

    func frame(at index: Int) -> CGRect? {
        index < frames.count ? frames[index] : nil
    }
}
#endif
