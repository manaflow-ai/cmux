#if os(iOS)
import CmuxMobileShellModel
import UIKit

/// UIKit owns the drag preview, insertion gap, cancellation and edge scrolling.
@MainActor
final class TerminalTabOverviewGridView: UICollectionView, UICollectionViewDataSource,
    UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    var onSelect: ((MobileTerminalPreview.ID) -> Void)?
    var onClose: ((MobileTerminalPreview.ID) -> Void)?
    var onReorder: (([MobileTerminalPreview.ID]) -> Void)?

    private var items: [TerminalTabOverviewItem] = []
    private var canCloseTabs = false
    private var pendingUpdate: (items: [TerminalTabOverviewItem], canClose: Bool)?
    private var isDraggingCard = false
    private var isDroppingCard = false
    private var isUpdatingCollection = false
    private let flowLayout = UICollectionViewFlowLayout()

    var cardViews: [MobileTerminalPreview.ID: TerminalTabOverviewCardView] {
        Dictionary(uniqueKeysWithValues: visibleCells.compactMap { cell in
            guard let cell = cell as? Cell, let id = cell.terminalID, let card = cell.card else { return nil }
            return (id, card)
        })
    }

    init() {
        super.init(frame: .zero, collectionViewLayout: flowLayout)
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = true
        clipsToBounds = false
        dataSource = self
        dragDelegate = self
        dropDelegate = self
        dragInteractionEnabled = true
        reorderingCadence = .immediate
        register(Cell.self, forCellWithReuseIdentifier: "terminal")
        accessibilityIdentifier = "MobileTerminalOverviewGrid"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(items: [TerminalTabOverviewItem], canClose: Bool) {
        // A preview refresh must not reload the cell UIKit is lifting. Apply
        // structural changes after its drop/cancel animation has completed.
        guard !isDraggingCard, !isDroppingCard, !isUpdatingCollection else {
            pendingUpdate = (items, canClose)
            return
        }
        let oldIDs = self.items.map(\.id)
        let newIDs = items.map(\.id)
        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)
        self.items = items
        canCloseTabs = canClose
        if oldIDs == newIDs {
            for case let cell as Cell in visibleCells {
                guard let item = items.first(where: { $0.id == cell.terminalID }) else { continue }
                configure(cell, item: item)
            }
        } else if window != nil, oldIDs.filter({ newSet.contains($0) }) == newIDs.filter({ oldSet.contains($0) }) {
            isUpdatingCollection = true
            performBatchUpdates {
                self.deleteItems(at: oldIDs.enumerated().compactMap {
                    newSet.contains($0.element) ? nil : IndexPath(item: $0.offset, section: 0)
                })
                self.insertItems(at: newIDs.enumerated().compactMap {
                    oldSet.contains($0.element) ? nil : IndexPath(item: $0.offset, section: 0)
                })
            } completion: { [weak self] _ in
                guard let self else { return }
                self.isUpdatingCollection = false
                // Recompute the last tab's close availability as well.
                self.update(items: self.items, canClose: self.canCloseTabs)
                self.applyPendingUpdate()
            }
        } else {
            reloadData()
        }
    }

    func layoutCards(safeArea: UIEdgeInsets, hintIsVisible: Bool, animated: Bool) {
        guard bounds.width > 0 else { return }
        let compact = items.count > 1
        let width = compact ? floor((bounds.width - 48) / 2) : min(268, bounds.width - 32)
        let height: CGFloat = compact ? 272 : 400
        let desiredTop = safeArea.top - frame.minY + (compact
            ? (hintIsVisible ? (items.count > 2 ? 153 : 212) : 60)
            : 210)
        let top = max(4, min(desiredTop, bounds.height - height - 14))
        let side = compact ? 16 : (bounds.width - width) / 2
        let insets = UIEdgeInsets(top: top, left: side, bottom: 16, right: side)
        let size = CGSize(width: max(0, width), height: height)
        guard flowLayout.itemSize != size || flowLayout.sectionInset != insets else { return }
        let changes = {
            self.flowLayout.itemSize = size
            self.flowLayout.minimumInteritemSpacing = 16
            self.flowLayout.minimumLineSpacing = 16
            self.flowLayout.sectionInset = insets
            self.flowLayout.invalidateLayout()
            self.layoutIfNeeded()
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.32, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    func card(for id: MobileTerminalPreview.ID, reveal: Bool) -> TerminalTabOverviewCardView? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let path = IndexPath(item: index, section: 0)
        layoutIfNeeded()
        if reveal, let frame = layoutAttributesForItem(at: path)?.frame {
            let visibleArea = bounds.insetBy(dx: 0, dy: 4)
            if !visibleArea.contains(frame) {
                scrollToItem(at: path, at: .centeredVertically, animated: false)
                layoutIfNeeded()
            }
        }
        return (cellForItem(at: path) as? Cell)?.card
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = dequeueReusableCell(withReuseIdentifier: "terminal", for: indexPath)
        if let cell = cell as? Cell { configure(cell, item: items[indexPath.item]) }
        return cell
    }

    private func configure(_ cell: Cell, item: TerminalTabOverviewItem) {
        cell.configure(item: item, canClose: canCloseTabs && item.canClose && items.count > 1)
        cell.card?.onSelect = { [weak self] in self?.onSelect?($0) }
        cell.card?.onClose = { [weak self] in self?.onClose?($0) }
    }

    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard items.count > 1 else { return [] }
        let id = items[indexPath.item].id
        let dragItem = UIDragItem(itemProvider: NSItemProvider(object: id.rawValue as NSString))
        dragItem.localObject = id
        session.localContext = self
        return [dragItem]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionWillBegin session: UIDragSession) {
        // UIKit balances this callback with didEnd, including cancellation.
        // Merely requesting drag items does not guarantee the lift completes.
        isDraggingCard = true
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let card = (cellForItem(at: indexPath) as? Cell)?.card else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 19)
        return parameters
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        guard session.localDragSession?.localContext as? TerminalTabOverviewGridView === self,
              session.items.count == 1 else { return UICollectionViewDropProposal(operation: .forbidden) }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard coordinator.proposal.operation == .move,
              let dropped = coordinator.items.first,
              let id = dropped.dragItem.localObject as? MobileTerminalPreview.ID,
              let source = items.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(coordinator.destinationIndexPath?.item ?? items.count - 1, items.count - 1)
        let destinationPath = IndexPath(item: destination, section: 0)
        isDroppingCard = true
        performBatchUpdates {
            let moved = self.items.remove(at: source)
            self.items.insert(moved, at: destination)
            self.moveItem(at: IndexPath(item: source, section: 0), to: destinationPath)
        } completion: { [weak self] _ in
            self?.isDroppingCard = false
            self?.applyPendingUpdate()
        }
        coordinator.drop(dropped.dragItem, toItemAt: destinationPath)
        onReorder?(items.map(\.id))
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        isDraggingCard = false
        applyPendingUpdate()
    }

    private func applyPendingUpdate() {
        guard !isDraggingCard, !isDroppingCard, !isUpdatingCollection, let pending = pendingUpdate else { return }
        pendingUpdate = nil
        // Keep the committed order when the queued refresh predates the drop.
        let byID = Dictionary(uniqueKeysWithValues: pending.items.map { ($0.id, $0) })
        let ordered = items.compactMap { byID[$0.id] }
        let retained = Set(ordered.map(\.id))
        update(items: ordered + pending.items.filter { !retained.contains($0.id) }, canClose: pending.canClose)
    }

    private final class Cell: UICollectionViewCell {
        private(set) var terminalID: MobileTerminalPreview.ID?
        private(set) var card: TerminalTabOverviewCardView?

        func configure(item: TerminalTabOverviewItem, canClose: Bool) {
            if terminalID != item.id {
                card?.removeFromSuperview()
                let card = TerminalTabOverviewCardView(item: item, canClose: canClose)
                contentView.addSubview(card)
                self.card = card
                terminalID = item.id
            } else {
                card?.update(item: item, canClose: canClose)
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            card?.frame = contentView.bounds
        }
    }
}
#endif
