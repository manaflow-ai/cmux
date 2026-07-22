import CMUXMobileCore
import CmuxMobileShellModel
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
}

struct PaneMapOverflowLabels {
    let leading: String
    let trailing: String
    let top: String
    let bottom: String
}

/// UIKit collection surface for native interactive movement and continuous zoom.
struct PaneMapCollectionView: UIViewRepresentable {
    let items: [PaneMapCollectionItem]
    let layout: MobilePaneLayout
    let terminalTheme: TerminalTheme
    let overflowLabels: PaneMapOverflowLabels
    let selectPreviewSurface: (_ paneID: String, _ surfaceID: String) -> Void
    let jumpToTerminal: (_ surfaceID: String) -> Void

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
        private var zoomSession: ZoomSession?

        init(parent: PaneMapCollectionView) {
            self.parent = parent
        }

        func attach(
            collectionView: UICollectionView,
            container: PaneMapCollectionContainerView
        ) {
            self.collectionView = collectionView
            self.container = container
            collectionView.dragInteractionEnabled = true
            collectionView.reorderingCadence = .immediate
            collectionView.dragDelegate = self
            collectionView.dropDelegate = self

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            collectionView.addGestureRecognizer(pinch)
        }

        func reconcile(items: [PaneMapCollectionItem]) {
            guard !isMovingItem else {
                pendingItems = items
                return
            }

            let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let retainedIDs = orderedItems.map(\.id).filter { itemsByID[$0] != nil }
            let retainedIDSet = Set(retainedIDs)
            let newIDs = items.map(\.id).filter { !retainedIDSet.contains($0) }
            orderedItems = (retainedIDs + newIDs).compactMap { itemsByID[$0] }
            collectionView?.reloadData()
            collectionView?.collectionViewLayout.invalidateLayout()
            container?.setNeedsLayout()
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
                    selectPreviewSurface: { [weak self] surfaceID in
                        self?.parent.selectPreviewSurface(item.pane.id, surfaceID)
                    },
                    jumpToTerminal: { [weak self] surfaceID in
                        self?.zoomToTerminal(paneID: item.pane.id, surfaceID: surfaceID)
                    }
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
            guard zoomSession == nil,
                  orderedItems.indices.contains(indexPath.item),
                  orderedItems.count > 1 else { return [] }
            isMovingItem = true
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

            collectionView.performBatchUpdates {
                let item = orderedItems.remove(at: sourceIndexPath.item)
                orderedItems.insert(item, at: destinationItem)
                collectionView.moveItem(at: sourceIndexPath, to: destinationIndexPath)
            }
            coordinator.drop(droppedItem.dragItem, toItemAt: destinationIndexPath)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dragSessionDidEnd session: UIDragSession
        ) {
            finishInteractiveMovement()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.updateOverflowIndicators()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer
                || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let collectionView else { return }
            switch gesture.state {
            case .began:
                let location = gesture.location(in: collectionView)
                guard let indexPath = collectionView.indexPathForItem(at: location),
                      startZoom(at: indexPath) else { return }
                collectionView.isScrollEnabled = false
            case .changed:
                guard zoomSession != nil else { return }
                let progress = min(1, max(0, (gesture.scale - 1) / 1.15))
                updateZoom(progress: progress)
            case .ended:
                guard let session = zoomSession else { return }
                let shouldCommit = session.progress > 0.32 || gesture.velocity > 1.4
                shouldCommit ? commitZoom() : cancelZoom()
            default:
                guard zoomSession != nil else { return }
                cancelZoom()
            }
        }

        private func finishInteractiveMovement() {
            isMovingItem = false
            collectionView?.collectionViewLayout.invalidateLayout()
            if let pendingItems {
                self.pendingItems = nil
                reconcile(items: pendingItems)
            }
        }

        private func zoomToTerminal(paneID: String, surfaceID: String) {
            guard zoomSession == nil,
                  let itemIndex = orderedItems.firstIndex(where: { $0.id == paneID }),
                  orderedItems[itemIndex].selectedSurface?.id == surfaceID,
                  startZoom(at: IndexPath(item: itemIndex, section: 0)) else {
                return
            }
            commitZoom()
        }

        private func startZoom(at indexPath: IndexPath) -> Bool {
            guard zoomSession == nil,
                  orderedItems.indices.contains(indexPath.item),
                  let surface = orderedItems[indexPath.item].selectedSurface,
                  surface.type.isTerminal,
                  let collectionView,
                  let cell = collectionView.cellForItem(at: indexPath),
                  let window = cell.window else {
                return false
            }

            let previewBounds = CGRect(
                x: 0,
                y: 0,
                width: cell.bounds.width,
                height: max(0, cell.bounds.height - PaneMapTileMetrics.captionHeight)
            )
            guard let snapshot = cell.resizableSnapshotView(
                from: previewBounds,
                afterScreenUpdates: true,
                withCapInsets: .zero
            ) else {
                return false
            }
            let initialFrame = cell.convert(previewBounds, to: window)
            let backdrop = UIView(frame: window.bounds)
            backdrop.backgroundColor = UIColor(terminalHex: parent.terminalTheme.background)
            backdrop.alpha = 0
            backdrop.isUserInteractionEnabled = false

            let wrapper = UIView(frame: initialFrame)
            wrapper.backgroundColor = UIColor(terminalHex: parent.terminalTheme.background)
            wrapper.clipsToBounds = true
            wrapper.layer.cornerCurve = .continuous
            wrapper.layer.cornerRadius = PaneMapTileMetrics.cornerRadius
            wrapper.isUserInteractionEnabled = false
            snapshot.frame = CGRect(origin: .zero, size: previewBounds.size)
            wrapper.addSubview(snapshot)

            window.addSubview(backdrop)
            window.addSubview(wrapper)
            cell.alpha = 0
            zoomSession = ZoomSession(
                surfaceID: surface.id,
                cell: cell,
                snapshot: snapshot,
                wrapper: wrapper,
                backdrop: backdrop,
                initialFrame: initialFrame,
                targetFrame: window.bounds,
                progress: 0
            )
            return true
        }

        private func updateZoom(progress: CGFloat) {
            guard var session = zoomSession else { return }
            session.progress = progress
            session.wrapper.frame = interpolate(
                from: session.initialFrame,
                to: session.targetFrame,
                progress: progress
            )
            session.snapshot.frame = session.wrapper.bounds
            session.wrapper.layer.cornerRadius = PaneMapTileMetrics.cornerRadius * (1 - progress)
            session.backdrop.alpha = progress
            zoomSession = session
        }

        private func commitZoom() {
            guard let session = zoomSession else { return }
            let remaining = max(0.16, 0.34 * (1 - session.progress))
            UIView.animate(
                withDuration: remaining,
                delay: 0,
                usingSpringWithDamping: 0.92,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .curveEaseOut]
            ) { [weak self] in
                self?.updateZoom(progress: 1)
            } completion: { [weak self] _ in
                guard let self, let committedSession = self.zoomSession else { return }
                self.parent.jumpToTerminal(committedSession.surfaceID)
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.finishZoom()
                }
            }
        }

        private func cancelZoom() {
            guard let session = zoomSession else { return }
            let remaining = max(0.16, 0.26 * session.progress)
            UIView.animate(
                withDuration: remaining,
                delay: 0,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .curveEaseOut]
            ) { [weak self] in
                self?.updateZoom(progress: 0)
            } completion: { [weak self] _ in
                self?.finishZoom()
            }
        }

        private func finishZoom() {
            guard let session = zoomSession else { return }
            session.cell.alpha = 1
            session.wrapper.removeFromSuperview()
            session.backdrop.removeFromSuperview()
            collectionView?.isScrollEnabled = true
            zoomSession = nil
        }

        private func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
            CGRect(
                x: start.minX + (end.minX - start.minX) * progress,
                y: start.minY + (end.minY - start.minY) * progress,
                width: start.width + (end.width - start.width) * progress,
                height: start.height + (end.height - start.height) * progress
            )
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

        private struct ZoomSession {
            let surfaceID: String
            let cell: UICollectionViewCell
            let snapshot: UIView
            let wrapper: UIView
            let backdrop: UIView
            let initialFrame: CGRect
            let targetFrame: CGRect
            var progress: CGFloat
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
        backgroundColor = UIColor(terminalHex: terminalTheme.background)
        self.scrollStep = scrollStep
        for button in buttons.values {
            button.tintColor = UIColor(terminalHex: terminalTheme.foreground)
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

private extension UIColor {
    convenience init(terminalHex: String) {
        guard let rgb = TerminalTheme.rgbComponents(terminalHex) else {
            self.init(white: 0, alpha: 1)
            return
        }
        self.init(
            red: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }
}
