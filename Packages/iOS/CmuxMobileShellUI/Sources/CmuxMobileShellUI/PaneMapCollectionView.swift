import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileTerminal
import SwiftUI
import UIKit

struct PaneMapCollectionItem: Equatable, Identifiable {
    let pane: MobilePaneNode
    let paneNumber: Int
    let paneCount: Int
    let isFocusedOnMac: Bool
    let selectedSurfaceID: String?
    let phoneSelectedSurfaceID: String?
    let preview: MobileTerminalPaneMapPreview?
    let isLoadingPreview: Bool
    let agentStateKind: ChatAgentStateKind?

    var id: String { pane.id }

    var selectedSurface: MobilePaneSurface? {
        guard let selectedSurfaceID else { return pane.surfaces.first }
        return pane.surfaces.first { $0.id == selectedSurfaceID }
    }

    /// The same pane content relabeled for a new visible position, so
    /// accessibility ordinals track optimistic reorders instead of waiting for
    /// the next authoritative snapshot.
    func withPanePosition(number: Int) -> PaneMapCollectionItem {
        PaneMapCollectionItem(
            pane: pane,
            paneNumber: number,
            paneCount: paneCount,
            isFocusedOnMac: isFocusedOnMac,
            selectedSurfaceID: selectedSurfaceID,
            phoneSelectedSurfaceID: phoneSelectedSurfaceID,
            preview: preview,
            isLoadingPreview: isLoadingPreview,
            agentStateKind: agentStateKind
        )
    }
}

struct PaneMapOverflowLabels {
    let leading: String
    let trailing: String
    let top: String
    let bottom: String
}

/// UIKit collection surface for native interactive movement and fluid system zoom sources.
struct PaneMapCollectionView: UIViewRepresentable {
    let items: [PaneMapCollectionItem]
    let layout: MobilePaneLayout
    let terminalTheme: TerminalTheme
    let zoomNamespace: Namespace.ID
    let overflowLabels: PaneMapOverflowLabels
    let allowsReordering: Bool
    let selectPreviewSurface: (_ paneID: String, _ surfaceID: String) -> Void
    let jumpToTerminal: (_ surfaceID: String) -> Void
    let reorderPanes: (_ orderedPaneIDs: [String], _ baseLayoutRevision: Int) async -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PaneMapCollectionContainerView {
        let collectionLayout = PaneMapCollectionLayout(paneLayout: layout)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: collectionLayout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceHorizontal = false
        collectionView.alwaysBounceVertical = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.showsHorizontalScrollIndicator = true
        collectionView.showsVerticalScrollIndicator = true
        collectionView.accessibilityIdentifier = "MobilePaneMapCollection"
        collectionView.register(
            UICollectionViewCell.self,
            forCellWithReuseIdentifier: Coordinator.cellReuseIdentifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator

        let container = PaneMapCollectionContainerView(collectionView: collectionView)
        container.configure(
            terminalTheme: terminalTheme,
            labels: overflowLabels,
            scrollStep: context.coordinator.scrollOneViewport
        )
        context.coordinator.attach(collectionView: collectionView, container: container)
        context.coordinator.reconcile(items: items)
        return container
    }

    func updateUIView(_ container: PaneMapCollectionContainerView, context: Context) {
        context.coordinator.parent = self
        if let collectionLayout = container.collectionView.collectionViewLayout
            as? PaneMapCollectionLayout {
            collectionLayout.paneLayout = layout
        }
        container.collectionView.dragInteractionEnabled = allowsReordering
        container.configure(
            terminalTheme: terminalTheme,
            labels: overflowLabels,
            scrollStep: context.coordinator.scrollOneViewport
        )
        context.coordinator.reconcile(items: items)
    }

    @MainActor
    final class Coordinator: NSObject,
        UICollectionViewDataSource,
        UICollectionViewDelegate,
        UICollectionViewDragDelegate,
        UICollectionViewDropDelegate,
        UIGestureRecognizerDelegate
    {
        static let cellReuseIdentifier = "PaneMapCollectionCell"

        var parent: PaneMapCollectionView
        private(set) var orderedItems: [PaneMapCollectionItem] = []
        private weak var collectionView: UICollectionView?
        private weak var container: PaneMapCollectionContainerView?
        private var isMovingItem = false
        private var pendingItems: [PaneMapCollectionItem]?
        private var authoritativeItemsByID: [String: PaneMapCollectionItem]
        private var reorderState: PaneMapReorderState
        private var selectionArbitration = PaneMapSelectionArbitration()
        private let tileMetrics = PaneMapTileMetrics()
        private let tabStripMetrics = PaneMapTabStripMetrics()

        init(parent: PaneMapCollectionView) {
            self.parent = parent
            // A malformed remote layout can repeat a pane ID; first-wins keeps
            // the coordinator alive instead of trapping on duplicate keys.
            authoritativeItemsByID = Dictionary(
                parent.items.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            reorderState = PaneMapReorderState(
                authoritativePaneIDs: Self.deduplicatedPaneIDs(parent.items),
                authoritativeRevision: parent.layout.version
            )
        }

        private static func deduplicatedPaneIDs(_ items: [PaneMapCollectionItem]) -> [String] {
            var seen: Set<String> = []
            return items.map(\.id).filter { seen.insert($0).inserted }
        }

        func attach(
            collectionView: UICollectionView,
            container: PaneMapCollectionContainerView
        ) {
            self.collectionView = collectionView
            self.container = container
            collectionView.dragInteractionEnabled = parent.allowsReordering
            collectionView.reorderingCadence = .immediate
            collectionView.dragDelegate = self
            collectionView.dropDelegate = self
            let resolvedTap = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleResolvedTap(_:))
            )
            resolvedTap.minimumPressDuration = 0
            resolvedTap.allowableMovement = 10
            resolvedTap.cancelsTouchesInView = false
            resolvedTap.delegate = self
            collectionView.addGestureRecognizer(resolvedTap)
        }

        func reconcile(items: [PaneMapCollectionItem]) {
            authoritativeItemsByID = Dictionary(
                items.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard !isMovingItem else {
                pendingItems = items
                return
            }

            reorderState.reconcile(
                authoritativePaneIDs: Self.deduplicatedPaneIDs(items),
                authoritativeRevision: parent.layout.version
            )
            reloadVisibleItems()
        }

        private func reloadVisibleItems() {
            orderedItems = reorderState.visiblePaneIDs
                .compactMap { authoritativeItemsByID[$0] }
                .enumerated()
                .map { index, item in item.withPanePosition(number: index + 1) }
            collectionView?.reloadData()
            collectionView?.collectionViewLayout.invalidateLayout()
            container?.setNeedsLayout()
            container?.prewarmDetachedCellLayout(estimatedSize: Self.detachedPrewarmSize())
        }

        private static func detachedPrewarmSize() -> CGSize {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            guard let scene else { return .zero }
            return scene.keyWindow?.bounds.size ?? scene.screen.bounds.size
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            orderedItems.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: Self.cellReuseIdentifier,
                for: indexPath
            )
            guard orderedItems.indices.contains(indexPath.item) else { return cell }
            let item = orderedItems[indexPath.item]
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.contentConfiguration = UIHostingConfiguration {
                PaneMapTileView(
                    item: item,
                    terminalTheme: parent.terminalTheme,
                    zoomNamespace: parent.zoomNamespace,
                    selectPreviewSurface: { [weak self] surfaceID in
                        self?.selectionArbitration.cancel()
                        self?.parent.selectPreviewSurface(item.pane.id, surfaceID)
                    },
                    jumpToTerminal: { [weak self] surfaceID in self?.resolveAccessibilitySelection(surfaceID) }
                )
            }
            .margins(.all, 0)
            .background(.clear)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            itemsForBeginning session: UIDragSession,
            at indexPath: IndexPath
        ) -> [UIDragItem] {
            guard parent.allowsReordering,
                  !reorderState.isMutationPending,
                  orderedItems.indices.contains(indexPath.item),
                  orderedItems.count > 1 else { return [] }
            isMovingItem = true
            selectionArbitration.dragSessionDidBegin()
            let itemID = orderedItems[indexPath.item].id
            let dragItem = UIDragItem(itemProvider: NSItemProvider(object: itemID as NSString))
            dragItem.localObject = itemID
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return [dragItem]
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dropSessionDidUpdate session: UIDropSession,
            withDestinationIndexPath destinationIndexPath: IndexPath?
        ) -> UICollectionViewDropProposal {
            guard session.localDragSession != nil else {
                return UICollectionViewDropProposal(operation: .forbidden)
            }
            return UICollectionViewDropProposal(
                operation: .move,
                intent: .insertAtDestinationIndexPath
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            performDropWith coordinator: UICollectionViewDropCoordinator
        ) {
            guard let droppedItem = coordinator.items.first,
                  let sourceIndexPath = droppedItem.sourceIndexPath,
                  orderedItems.indices.contains(sourceIndexPath.item) else { return }
            let proposedDestination = coordinator.destinationIndexPath
                ?? IndexPath(item: orderedItems.count - 1, section: 0)
            let destinationItem = min(
                max(0, proposedDestination.item),
                orderedItems.count - 1
            )
            let destinationIndexPath = IndexPath(item: destinationItem, section: 0)
            guard let request = reorderState.beginMove(
                from: sourceIndexPath.item,
                to: destinationItem
            ) else {
                return
            }

            collectionView.performBatchUpdates {
                let item = orderedItems.remove(at: sourceIndexPath.item)
                orderedItems.insert(item, at: destinationItem)
                collectionView.moveItem(at: sourceIndexPath, to: destinationIndexPath)
            }
            coordinator.drop(droppedItem.dragItem, toItemAt: destinationIndexPath)
            // Moved cells keep their pre-drag ordinals until reconfigured;
            // relabel the optimistic order so VoiceOver reads the position the
            // pane actually occupies during the mutation window.
            orderedItems = orderedItems.enumerated().map { index, item in
                item.withPanePosition(number: index + 1)
            }
            collectionView.reconfigureItems(at: collectionView.indexPathsForVisibleItems)
            Task { [weak self] in
                guard let self else { return }
                let succeeded = await parent.reorderPanes(
                    request.orderedPaneIDs,
                    request.baseLayoutRevision
                )
                completeReorder(requestID: request.id, succeeded: succeeded)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dragSessionDidEnd session: UIDragSession
        ) {
            finishInteractiveMovement()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.updateOverflowIndicators()
            selectionArbitration.touchMoved(
                to: scrollView.panGestureRecognizer.location(in: scrollView)
            )
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            selectionArbitration.dragSessionDidBegin()
        }

        private func finishInteractiveMovement() {
            isMovingItem = false
            collectionView?.collectionViewLayout.invalidateLayout()
            if let pendingItems {
                self.pendingItems = nil
                reconcile(items: pendingItems)
            }
        }

        private func completeReorder(requestID: UUID, succeeded: Bool) {
            let completion = reorderState.complete(
                requestID: requestID,
                succeeded: succeeded
            )
            guard completion != .ignored else { return }
            if completion == .rolledBack {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            reloadVisibleItems()
        }

        private func resolveAccessibilitySelection(_ surfaceID: String) {
            guard !isMovingItem, !reorderState.isMutationPending else { return }
            parent.jumpToTerminal(surfaceID)
        }

        @objc private func handleResolvedTap(_ gesture: UILongPressGestureRecognizer) {
            guard let collectionView else { return }
            let location = gesture.location(in: collectionView)
            switch gesture.state {
            case .began:
                selectionArbitration.touchBegan(at: location)
            case .changed:
                selectionArbitration.touchMoved(to: location)
            case .ended:
                guard selectionArbitration.touchEnded(at: location),
                      !isMovingItem,
                      !reorderState.isMutationPending,
                      let indexPath = collectionView.indexPathForItem(at: location),
                      orderedItems.indices.contains(indexPath.item),
                      !isPointInTabSwitcher(
                        location,
                        indexPath: indexPath,
                        collectionView: collectionView
                      ),
                      let surfaceID = orderedItems[indexPath.item].selectedSurface?.id,
                      orderedItems[indexPath.item].selectedSurface?.type.isTerminal == true else {
                    return
                }
                parent.jumpToTerminal(surfaceID)
            case .cancelled, .failed:
                selectionArbitration.cancel()
            default:
                break
            }
        }

        private func isPointInTabSwitcher(
            _ collectionLocation: CGPoint,
            indexPath: IndexPath,
            collectionView: UICollectionView
        ) -> Bool {
            guard orderedItems[indexPath.item].pane.surfaces.count > 1,
                  let cell = collectionView.cellForItem(at: indexPath) else {
                return false
            }
            let previewBounds = CGRect(
                x: cell.frame.minX,
                y: cell.frame.minY,
                width: cell.frame.width,
                height: max(0, cell.bounds.height - tileMetrics.captionHeight)
            )
            return tabStripMetrics.frame(
                in: previewBounds,
                tabCount: orderedItems[indexPath.item].pane.surfaces.count
            ).contains(collectionLocation)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dragPreviewParametersForItemAt indexPath: IndexPath
        ) -> UIDragPreviewParameters? {
            guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(
                roundedRect: cell.bounds,
                cornerRadius: tileMetrics.cornerRadius
            )
            return parameters
        }

        func scrollOneViewport(_ direction: PaneMapOverflowDirection) {
            guard let collectionView else { return }
            let horizontalStep = max(80, collectionView.bounds.width * 0.72)
            let verticalStep = max(80, collectionView.bounds.height * 0.72)
            var offset = collectionView.contentOffset
            switch direction {
            case .leading:
                offset.x -= horizontalStep
            case .trailing:
                offset.x += horizontalStep
            case .top:
                offset.y -= verticalStep
            case .bottom:
                offset.y += verticalStep
            }
            let maximumOffset = CGPoint(
                x: max(0, collectionView.contentSize.width - collectionView.bounds.width),
                y: max(0, collectionView.contentSize.height - collectionView.bounds.height)
            )
            offset.x = min(maximumOffset.x, max(0, offset.x))
            offset.y = min(maximumOffset.y, max(0, offset.y))
            collectionView.setContentOffset(offset, animated: true)
        }
    }
}

enum PaneMapOverflowDirection: CaseIterable {
    case leading
    case trailing
    case top
    case bottom

    var systemImage: String {
        switch self {
        case .leading: "chevron.left"
        case .trailing: "chevron.right"
        case .top: "chevron.up"
        case .bottom: "chevron.down"
        }
    }
}

final class PaneMapCollectionContainerView: UIView {
    let collectionView: UICollectionView
    private var buttons: [PaneMapOverflowDirection: PaneMapOverflowButton] = [:]
    private var scrollStep: ((PaneMapOverflowDirection) -> Void)?
    private var lastLayoutSize: CGSize = .zero

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
        super.init(frame: .zero)
        addSubview(collectionView)
        for direction in PaneMapOverflowDirection.allCases {
            let button = PaneMapOverflowButton(direction: direction)
            button.addAction(UIAction { [weak self] _ in
                self?.scrollStep?(direction)
            }, for: .primaryActionTriggered)
            buttons[direction] = button
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        terminalTheme: TerminalTheme,
        labels: PaneMapOverflowLabels,
        scrollStep: @escaping (PaneMapOverflowDirection) -> Void
    ) {
        backgroundColor = terminalTheme.terminalBackgroundUIColor
        self.scrollStep = scrollStep
        for button in buttons.values {
            button.tintColor = terminalTheme.terminalForegroundUIColor
        }
        buttons[.leading]?.accessibilityLabel = labels.leading
        buttons[.trailing]?.accessibilityLabel = labels.trailing
        buttons[.top]?.accessibilityLabel = labels.top
        buttons[.bottom]?.accessibilityLabel = labels.bottom
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds
        let buttonSize = CGSize(width: 38, height: 38)
        let horizontalY = bounds.midY - buttonSize.height / 2
        let verticalX = bounds.midX - buttonSize.width / 2
        buttons[.leading]?.frame = CGRect(
            x: 6,
            y: horizontalY,
            width: buttonSize.width,
            height: buttonSize.height
        )
        buttons[.trailing]?.frame = CGRect(
            x: bounds.maxX - buttonSize.width - 6,
            y: horizontalY,
            width: buttonSize.width,
            height: buttonSize.height
        )
        buttons[.top]?.frame = CGRect(
            x: verticalX,
            y: 6,
            width: buttonSize.width,
            height: buttonSize.height
        )
        buttons[.bottom]?.frame = CGRect(
            x: verticalX,
            y: bounds.maxY - buttonSize.height - 6,
            width: buttonSize.width,
            height: buttonSize.height
        )
        if lastLayoutSize != bounds.size {
            lastLayoutSize = bounds.size
            collectionView.collectionViewLayout.invalidateLayout()
        }
        collectionView.layoutIfNeeded()
        updateOverflowIndicators()
    }

    /// Materializes the map's cells while this view has no window.
    ///
    /// The map is the navigation-stack root and a restored workspace starts
    /// with the terminal pushed on top, so UIKit never lays this view out
    /// before the first terminal→map pop. The zoom transition's matched
    /// source tile lives inside a cell; if no cell exists when that pop
    /// begins, the unzoom degrades to a hard cut. Sizing the detached
    /// container to the scene estimate and forcing layout creates the tiles
    /// ahead of the first pop; the real layout pass corrects the geometry.
    func prewarmDetachedCellLayout(estimatedSize: CGSize) {
        guard window == nil else { return }
        if bounds.size == .zero {
            guard estimatedSize != .zero else { return }
            frame = CGRect(origin: .zero, size: estimatedSize)
        }
        layoutIfNeeded()
    }

    func updateOverflowIndicators() {
        let maximumX = max(0, collectionView.contentSize.width - collectionView.bounds.width)
        let maximumY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        let offset = collectionView.contentOffset
        buttons[.leading]?.isHidden = maximumX <= 1 || offset.x <= 4
        buttons[.trailing]?.isHidden = maximumX <= 1 || offset.x >= maximumX - 4
        buttons[.top]?.isHidden = maximumY <= 1 || offset.y <= 4
        buttons[.bottom]?.isHidden = maximumY <= 1 || offset.y >= maximumY - 4
    }
}

private final class PaneMapOverflowButton: UIButton {
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))

    init(direction: PaneMapOverflowDirection) {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        tintColor = .label
        setImage(UIImage(systemName: direction.systemImage), for: .normal)
        imageView?.contentMode = .scaleAspectFit
        blurView.isUserInteractionEnabled = false
        blurView.clipsToBounds = true
        insertSubview(blurView, at: 0)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        blurView.layer.cornerRadius = bounds.width / 2
    }
}

