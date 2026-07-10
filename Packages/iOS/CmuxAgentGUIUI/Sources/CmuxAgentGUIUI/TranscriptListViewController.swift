#if os(iOS)
public import CmuxAgentGUIProjection
import SwiftUI
public import UIKit

/// UIKit transcript list with flipped collection-view physics.
@MainActor public final class TranscriptListViewController: UIViewController {
    /// The collection view that owns transcript virtualization and scroll physics.
    public private(set) var collectionView: UICollectionView!

    private let projector = TranscriptProjector()
    private let transactionQueue = TranscriptTransactionQueue()
    private let measurementCache = TranscriptMeasurementCache()
    private var dataSource: UICollectionViewDiffableDataSource<TranscriptListSection, TranscriptRowID>!
    private var rowsByID: [TranscriptRowID: TranscriptMeasuredRow] = [:]
    private var currentRows: [TranscriptRow] = []
    private var scrollAnimator: UIViewPropertyAnimator?
    var keyboardAnimator: UIViewPropertyAnimator?
    var pillHost: UIHostingController<ScrollToBottomPill>?
    var unreadCount = 0
    var renderedPillUnreadCount = 0
    var currentKeyboardInset: CGFloat = 0
    private var latestInput: TranscriptProjectionInput?
    private var transactionGeneration = 0
    private var measurementConfiguration: TranscriptMeasurementConfiguration?

    /// Creates the transcript list controller.
    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The current physical bottom obstruction reported by `keyboardLayoutGuide`.
    public var keyboardBottomInset: CGFloat {
        currentKeyboardInset
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
        configurePill()
        configureKeyboardObservation()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateVisualEdgeInsets(preservingBottomPosition: true)
        guard let latestInput,
              let configuration = currentMeasurementConfiguration,
              configuration != measurementConfiguration
        else {
            return
        }
        enqueueProjection(latestInput, configuration: configuration)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Applies a replica projection input through the serial transaction queue.
    /// - Parameter input: The platform-neutral projection input.
    public func apply(input: TranscriptProjectionInput) {
        loadViewIfNeeded()
        latestInput = input
        guard let configuration = currentMeasurementConfiguration else {
            return
        }
        enqueueProjection(input, configuration: configuration)
    }

    private func enqueueProjection(
        _ input: TranscriptProjectionInput,
        configuration: TranscriptMeasurementConfiguration
    ) {
        let projection = projector.project(input, previousRows: currentRows)
        let existingIDs = Set(currentRows.map(\.rowID))
        let configurationChanged = measurementConfiguration != nil
            && measurementConfiguration != configuration
        let diff: TranscriptProjectionDiff
        if configurationChanged {
            diff = TranscriptProjectionDiff(
                inserted: projection.diff.inserted,
                removed: projection.diff.removed,
                moved: projection.diff.moved,
                updated: projection.diff.updated.union(
                    projection.rows.lazy.map(\.rowID).filter(existingIDs.contains)
                )
            )
        } else {
            diff = projection.diff
        }
        measurementConfiguration = configuration
        currentRows = projection.rows
        unreadCount = projection.rows.filter(\.isUnread).count
        let width = effectiveMeasurementWidth
        transactionGeneration += 1
        let generation = transactionGeneration
        Task {
            await transactionQueue.enqueue(
                generation: generation,
                rows: projection.rows,
                diff: diff,
                width: width,
                environment: configuration.environment,
                cache: measurementCache
            ) { [weak self] measured, measuredDiff in
                self?.applyMeasuredRows(measured, diff: measuredDiff)
            }
        }
    }

    /// Scrolls to the newest transcript row in flipped space.
    public func scrollToBottom(animated: Bool = true) {
        scrollAnimator?.stopAnimation(true)
        let updates: () -> Void = { [weak self] in
            guard let self else {
                return
            }
            self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
        }
        guard animated else {
            updates()
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.35, curve: .easeOut, animations: updates)
        scrollAnimator = animator
        animator.startAnimation()
    }

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        let collection = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = .systemBackground
        collection.transform = CGAffineTransform(scaleX: 1, y: -1)
        collection.contentInsetAdjustmentBehavior = .never
        collection.keyboardDismissMode = .interactive
        collection.scrollsToTop = false
        collection.alwaysBounceVertical = true
        collection.delegate = self
        collection.register(TranscriptCollectionCell.self, forCellWithReuseIdentifier: "TranscriptCollectionCell")
        view.addSubview(collection)
        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: view.topAnchor),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        collectionView = collection
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<TranscriptListSection, TranscriptRowID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, rowID in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: "TranscriptCollectionCell",
                for: indexPath
            ) as? TranscriptCollectionCell
            guard let cell, let measured = self?.rowsByID[rowID] else {
                return UICollectionViewCell()
            }
            cell.configure(row: measured.row, measuredHeight: measured.height)
            return cell
        }
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
        #if DEBUG
        (collectionView as? TranscriptCollectionView)?.allowsReloadData = false
        #endif
    }

    private func applyMeasuredRows(
        _ measured: [TranscriptMeasuredRow],
        diff: TranscriptProjectionDiff
    ) {
        let wasNearBottom = distanceFromBottom <= 40
        let anchor = wasNearBottom ? nil : captureAnchor()
        rowsByID = Dictionary(uniqueKeysWithValues: measured.map { ($0.row.rowID, $0) })
        let previousIDs = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(measured.map(\.row.rowID), toSection: .main)
        let reconfigured = diff.updated.filter(previousIDs.contains)
        if !reconfigured.isEmpty {
            snapshot.reconfigureItems(Array(reconfigured))
        }
        if wasNearBottom {
            dataSource.apply(snapshot, animatingDifferences: true) { [weak self] in
                guard let self else { return }
                self.collectionView.layoutIfNeeded()
                self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
                (self.collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
                self.updatePillVisibility()
            }
        } else {
            UIView.performWithoutAnimation {
                self.dataSource.apply(snapshot, animatingDifferences: false)
                self.collectionView.layoutIfNeeded()
                if let anchor {
                    self.restore(anchor: anchor)
                }
            }
            (collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
            updatePillVisibility()
        }
    }

    private func captureAnchor() -> TranscriptAnchorSnapshot? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        guard let indexPath = visible.first,
              let rowID = dataSource.itemIdentifier(for: indexPath),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        else {
            return nil
        }
        let screenY = collectionView.convert(attributes.frame, to: view).minY
        return TranscriptAnchorSnapshot(rowID: rowID, screenY: screenY)
    }

    private func restore(anchor: TranscriptAnchorSnapshot) {
        guard let indexPath = dataSource.indexPath(for: anchor.rowID),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        else {
            return
        }
        let newScreenY = collectionView.convert(attributes.frame, to: view).minY
        // Flipped space: d(screenY)/d(offset) = +1, so holding the anchor's
        // screen position requires subtracting the screen-space displacement.
        collectionView.contentOffset.y -= newScreenY - anchor.screenY
    }

    private var currentMeasurementConfiguration: TranscriptMeasurementConfiguration? {
        let width = effectiveMeasurementWidth
        guard width > 1 else {
            return nil
        }
        return TranscriptMeasurementConfiguration(
            widthBucket: Int((width / 8).rounded(.toNearestOrAwayFromZero)),
            environment: TranscriptMeasurementEnvironment(
                contentSizeCategory: traitCollection.preferredContentSizeCategory.rawValue,
                userInterfaceStyle: traitCollection.userInterfaceStyle.rawValue
            )
        )
    }

    var bottomRestOffset: CGPoint {
        CGPoint(x: -collectionView.contentInset.left, y: -collectionView.contentInset.top)
    }

    func updateVisualEdgeInsets(preservingBottomPosition: Bool) {
        let oldRestOffset = bottomRestOffset
        let wasNearBottom = distanceFromBottom <= 40
        let safeArea = view.safeAreaInsets
        let mappedInsets = UIEdgeInsets(
            top: safeArea.bottom + currentKeyboardInset,
            left: safeArea.left,
            bottom: safeArea.top,
            right: safeArea.right
        )
        guard collectionView.contentInset != mappedInsets else {
            return
        }
        collectionView.contentInset = mappedInsets
        collectionView.verticalScrollIndicatorInsets = mappedInsets
        guard preservingBottomPosition, wasNearBottom else {
            return
        }
        let newRestOffset = bottomRestOffset
        collectionView.contentOffset.x += newRestOffset.x - oldRestOffset.x
        collectionView.contentOffset.y += newRestOffset.y - oldRestOffset.y
    }

    private var effectiveMeasurementWidth: CGFloat {
        max(1, collectionView.bounds.width - collectionView.contentInset.left - collectionView.contentInset.right)
    }
}

extension TranscriptListViewController: UICollectionViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollAnimator?.stopAnimation(true)
        keyboardAnimator?.stopAnimation(true)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        (collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
        updatePillVisibility()
    }
}
#endif
