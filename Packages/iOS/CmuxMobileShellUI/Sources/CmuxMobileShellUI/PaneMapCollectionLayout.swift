import CmuxMobileShellModel
import UIKit

/// Pure constrained layout used by the pane-map collection view.
struct PaneMapCollectionLayoutEngine {
    struct Insets: Equatable {
        let top: CGFloat
        let leading: CGFloat
        let bottom: CGFloat
        let trailing: CGFloat

        static let paneMap = Insets(top: 8, leading: 16, bottom: 16, trailing: 16)
    }

    struct Result: Equatable {
        let framesByPaneID: [String: CGRect]
        let orderedFrames: [CGRect]
        let contentSize: CGSize
        let overflowsHorizontally: Bool
        let overflowsVertically: Bool
    }

    let minimumItemSize: CGSize
    let spacing: CGFloat
    let insets: Insets

    init(
        minimumItemSize: CGSize = CGSize(width: 156, height: 220),
        spacing: CGFloat = 14,
        insets: Insets = .paneMap
    ) {
        self.minimumItemSize = minimumItemSize
        self.spacing = spacing
        self.insets = insets
    }

    func layout(_ layout: MobilePaneLayout, in viewportSize: CGSize) -> Result {
        let viewportWidth = max(0, viewportSize.width)
        let viewportHeight = max(0, viewportSize.height)
        let availableSize = CGSize(
            width: max(0, viewportWidth - insets.leading - insets.trailing),
            height: max(0, viewportHeight - insets.top - insets.bottom)
        )
        let minimumRootSize = minimumSize(for: layout.root)
        let rootSize = CGSize(
            width: max(availableSize.width, minimumRootSize.width),
            height: max(availableSize.height, minimumRootSize.height)
        )
        let rootRect = CGRect(
            x: insets.leading,
            y: insets.top,
            width: rootSize.width,
            height: rootSize.height
        )

        var framesByPaneID: [String: CGRect] = [:]
        appendFrames(for: layout.root, in: rootRect, to: &framesByPaneID)
        let contentSize = CGSize(
            width: rootSize.width + insets.leading + insets.trailing,
            height: rootSize.height + insets.top + insets.bottom
        )
        return Result(
            framesByPaneID: framesByPaneID,
            orderedFrames: layout.orderedPanes.compactMap { framesByPaneID[$0.id] },
            contentSize: contentSize,
            overflowsHorizontally: contentSize.width > viewportWidth + 0.5,
            overflowsVertically: contentSize.height > viewportHeight + 0.5
        )
    }

    private func minimumSize(for node: MobilePaneLayout.Node) -> CGSize {
        switch node {
        case .pane:
            return minimumItemSize
        case let .split(split):
            let first = minimumSize(for: split.first)
            let second = minimumSize(for: split.second)
            switch split.orientation {
            case .horizontal:
                return CGSize(
                    width: first.width + spacing + second.width,
                    height: max(first.height, second.height)
                )
            case .vertical:
                return CGSize(
                    width: max(first.width, second.width),
                    height: first.height + spacing + second.height
                )
            }
        }
    }

    private func appendFrames(
        for node: MobilePaneLayout.Node,
        in rect: CGRect,
        to framesByPaneID: inout [String: CGRect]
    ) {
        switch node {
        case let .pane(pane):
            framesByPaneID[pane.id] = rect.integral
        case let .split(split):
            let firstMinimum = minimumSize(for: split.first)
            let secondMinimum = minimumSize(for: split.second)
            let firstRect: CGRect
            let secondRect: CGRect

            switch split.orientation {
            case .horizontal:
                let distributableWidth = max(0, rect.width - spacing)
                let firstWidth = constrainedLength(
                    preferred: distributableWidth * CGFloat(split.ratio),
                    total: distributableWidth,
                    firstMinimum: firstMinimum.width,
                    secondMinimum: secondMinimum.width
                )
                firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: firstWidth,
                    height: rect.height
                )
                secondRect = CGRect(
                    x: firstRect.maxX + spacing,
                    y: rect.minY,
                    width: max(0, distributableWidth - firstWidth),
                    height: rect.height
                )
            case .vertical:
                let distributableHeight = max(0, rect.height - spacing)
                let firstHeight = constrainedLength(
                    preferred: distributableHeight * CGFloat(split.ratio),
                    total: distributableHeight,
                    firstMinimum: firstMinimum.height,
                    secondMinimum: secondMinimum.height
                )
                firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: firstHeight
                )
                secondRect = CGRect(
                    x: rect.minX,
                    y: firstRect.maxY + spacing,
                    width: rect.width,
                    height: max(0, distributableHeight - firstHeight)
                )
            }

            appendFrames(for: split.first, in: firstRect, to: &framesByPaneID)
            appendFrames(for: split.second, in: secondRect, to: &framesByPaneID)
        }
    }

    private func constrainedLength(
        preferred: CGFloat,
        total: CGFloat,
        firstMinimum: CGFloat,
        secondMinimum: CGFloat
    ) -> CGFloat {
        min(
            max(preferred, firstMinimum),
            max(firstMinimum, total - secondMinimum)
        )
    }
}

/// UICollectionView layout that assigns the constrained pane slots by depth-first order.
final class PaneMapCollectionLayout: UICollectionViewLayout {
    var paneLayout: MobilePaneLayout {
        didSet {
            guard paneLayout != oldValue else { return }
            invalidateLayout()
        }
    }

    private let engine: PaneMapCollectionLayoutEngine
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var result: PaneMapCollectionLayoutEngine.Result?

    init(
        paneLayout: MobilePaneLayout,
        engine: PaneMapCollectionLayoutEngine = PaneMapCollectionLayoutEngine()
    ) {
        self.paneLayout = paneLayout
        self.engine = engine
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let result = engine.layout(paneLayout, in: collectionView.bounds.size)
        self.result = result
        let itemCount = collectionView.numberOfItems(inSection: 0)
        attributes = (0..<min(itemCount, result.orderedFrames.count)).map { item in
            let attributes = UICollectionViewLayoutAttributes(
                forCellWith: IndexPath(item: item, section: 0)
            )
            attributes.frame = result.orderedFrames[item]
            return attributes
        }
    }

    override var collectionViewContentSize: CGSize {
        result?.contentSize ?? .zero
    }

    override func layoutAttributesForElements(
        in rect: CGRect
    ) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return collectionView.bounds.size != newBounds.size
    }
}
