#if os(iOS)
import CMUXMobileCore
public import CmuxAgentGUIProjection
import SwiftUI
public import UIKit
/// UIKit transcript list with flipped collection-view physics.
@MainActor public final class TranscriptListViewController: UIViewController {
    /// The collection view that owns transcript virtualization and scroll physics.
    public private(set) var collectionView: UICollectionView!
    private let projector = TranscriptProjector()
    var currentTheme: AgentGUITheme
    private var dataSource: UICollectionViewDiffableDataSource<TranscriptListSection, TranscriptRowID>!
    private var rowsByID: [TranscriptRowID: TranscriptRow] = [:]
    private var spacingByID: [TranscriptRowID: TranscriptRowSpacing] = [:]
    private var currentRows: [TranscriptRow] = []
    private var latestInput: TranscriptProjectionInput?
    private var scrollAnimator: UIViewPropertyAnimator?
    var isAutoStickingToBottom = false
    private var jumpSnapshotView: UIView?
    private var collectionViewportView: UIView!
    private var collectionMotionView: UIView!
    private var collectionViewportBottomConstraint: NSLayoutConstraint!
    private var collectionViewportHeightConstraint: NSLayoutConstraint!
    var bottomChromeHeight: CGFloat = 0
    private var unreadTracker = TranscriptUnreadTracker()
    var pillChromeView: UIView?
    var pillHost: UIHostingController<ScrollToBottomPill>?
    var pillBottomConstraint: NSLayoutConstraint?
    var unreadCount = 0
    var renderedPillUnreadCount = 0
    private var topMaskView: TranscriptPinnedTopMaskView?
    private var bottomMaskView: TranscriptPinnedBottomMaskView?

    /// Creates the transcript list controller.
    public init(theme: AgentGUITheme) {
        currentTheme = theme
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The current physical bottom obstruction reported by `keyboardLayoutGuide`.
    public var keyboardBottomInset: CGFloat {
        guard isViewLoaded else { return 0 }
        let obstruction = view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY
        return pixelRounded(max(0, obstruction - view.safeAreaInsets.bottom))
    }

    public override func loadView() {
        view = TranscriptChromePassthroughView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(currentTheme.background)
        view.clipsToBounds = true
        configureCollectionView()
        configureDataSource()
        configurePill()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCollectionViewportConstraints()
        updateVisualEdgeInsets(preservingBottomPosition: true)
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelActiveScrollTransition()
    }

    /// Applies a replica projection input to the identity-stable collection snapshot.
    /// - Parameter input: The platform-neutral projection input.
    public func apply(input: TranscriptProjectionInput) {
        loadViewIfNeeded()
        latestInput = input
        let projection = projector.project(input, previousRows: currentRows)
        currentRows = projection.rows
        applyRows(projection.rows, diff: projection.diff)
    }
    /// Recolors the mounted transcript and chrome without replacing the list controller.
    public func apply(theme: AgentGUITheme) {
        guard theme != currentTheme else {
            return
        }
        currentTheme = theme
        guard isViewLoaded else {
            return
        }
        let anchor = captureAnchor()
        view.backgroundColor = UIColor(theme.background)
        collectionView.backgroundColor = UIColor(theme.background)
        topMaskView?.apply(theme: theme)
        bottomMaskView?.apply(theme: theme)
        refreshPillTheme()
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
            if let anchor {
                restore(anchor: anchor)
            }
        }
    }

    /// Scrolls to the newest transcript row in flipped space.
    public func scrollToBottom(animated: Bool = true) {
        cancelActiveScrollTransition()
        flushLatestProjectionForJump { [weak self] in
            self?.performScrollToBottom(animated: animated)
        }
    }

    private func performScrollToBottom(animated: Bool) {
        guard animated, distanceFromBottom > 44 else {
            collectionView.setContentOffset(bottomRestOffset, animated: false)
            updateUnreadCountFromVisibility()
            updatePillVisibility()
            return
        }
        collectionView.layoutIfNeeded()
        guard let oldSnapshot = collectionMotionView.snapshotView(afterScreenUpdates: false) else {
            collectionView.setContentOffset(bottomRestOffset, animated: false)
            updateUnreadCountFromVisibility()
            updatePillVisibility()
            return
        }
        let travel = max(1, collectionViewportView.bounds.height)
        oldSnapshot.frame = collectionViewportView.bounds
        oldSnapshot.isUserInteractionEnabled = false
        collectionViewportView.addSubview(oldSnapshot)
        jumpSnapshotView = oldSnapshot
        UIView.performWithoutAnimation {
            self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
            self.collectionView.layoutIfNeeded()
            self.collectionMotionView.transform = CGAffineTransform(translationX: 0, y: travel)
        }
        let animator = UIViewPropertyAnimator(duration: 0.25, curve: .easeOut) { [weak self, weak oldSnapshot] in
            self?.collectionMotionView.transform = .identity
            oldSnapshot?.transform = CGAffineTransform(translationX: 0, y: -travel)
        }
        scrollAnimator = animator
        animator.addCompletion { [weak self, weak animator, weak oldSnapshot] _ in
            oldSnapshot?.removeFromSuperview()
            guard let self, self.scrollAnimator === animator else { return }
            self.collectionMotionView.transform = .identity
            self.jumpSnapshotView = nil
            self.scrollAnimator = nil
            self.updateUnreadCountFromVisibility()
            self.updatePillVisibility()
        }
        animator.startAnimation()
    }

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        let collection = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = UIColor(currentTheme.background)
        collection.transform = CGAffineTransform(scaleX: 1, y: -1)
        collection.contentInsetAdjustmentBehavior = .never
        collection.keyboardDismissMode = .interactive
        collection.scrollsToTop = false
        collection.alwaysBounceVertical = true
        collection.bounces = true
        if #available(iOS 17.4, *) {
            collection.bouncesVertically = true
        }
        collection.delegate = self
        collection.register(TranscriptCollectionCell.self, forCellWithReuseIdentifier: "TranscriptCollectionCell")
        let viewport = UIView()
        viewport.translatesAutoresizingMaskIntoConstraints = false
        viewport.clipsToBounds = true
        let motionView = UIView()
        motionView.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(motionView)
        motionView.addSubview(collection)
        view.addSubview(viewport)
        let bottomConstraint = viewport.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        let heightConstraint = viewport.heightAnchor.constraint(equalTo: view.heightAnchor)
        NSLayoutConstraint.activate([
            viewport.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
            heightConstraint,
            motionView.topAnchor.constraint(equalTo: viewport.topAnchor),
            motionView.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            motionView.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            motionView.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            collection.topAnchor.constraint(equalTo: motionView.topAnchor),
            collection.leadingAnchor.constraint(equalTo: motionView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: motionView.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: motionView.bottomAnchor),
        ])
        collectionViewportView = viewport
        collectionMotionView = motionView
        collectionViewportBottomConstraint = bottomConstraint
        collectionViewportHeightConstraint = heightConstraint
        collectionView = collection
        configureScrollEdgeEffects(for: collection)
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<TranscriptListSection, TranscriptRowID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, rowID in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: "TranscriptCollectionCell",
                for: indexPath
            ) as? TranscriptCollectionCell
            guard let self,
                  let cell,
                  let row = rowsByID[rowID],
                  let spacing = spacingByID[rowID]
            else {
                return UICollectionViewCell()
            }
            cell.configure(row: row, spacing: spacing, theme: currentTheme)
            return cell
        }
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
        #if DEBUG
        (collectionView as? TranscriptCollectionView)?.allowsReloadData = false
        #endif
    }

    private func applyRows(
        _ rows: [TranscriptRow],
        diff: TranscriptProjectionDiff
    ) {
        cancelActiveScrollTransition()
        let policy = TranscriptMutationApplyPolicy(
            scrollIsInteracting: isScrollInteractionActive,
            distanceFromBottom: Double(distanceFromBottom),
            insertedIndexes: Array(diff.inserted.values)
        )
        let mode = policy.mode
        #if DEBUG
        if isScrollInteractionActive, mode == .animatedIdleAtBottom {
            assertionFailure("Transcript mutations must not animate while the scroll view is tracking, dragging, or decelerating")
        }
        #endif
        let anchor = mode == .nonAnimatedPreservingAnchor ? captureAnchor() : nil
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.rowID, $0) })
        spacingByID = TranscriptRowSpacing.resolved(for: rows)
        let previousIDs = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(rows.map(\.rowID), toSection: .main)
        let reconfigured = diff.updated.filter(previousIDs.contains)
        if !reconfigured.isEmpty {
            snapshot.reconfigureItems(Array(reconfigured))
        }
        if mode == .animatedIdleAtBottom {
            let anchor = captureAnchor()
            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.dataSource.apply(snapshot, animatingDifferences: false)
                self.collectionView.layoutIfNeeded()
                if let anchor {
                    self.restore(anchor: anchor)
                }
                CATransaction.commit()
            }
            isAutoStickingToBottom = true
            updateUnreadCountFromVisibility()
            updatePillVisibility()
            let animator = UIViewPropertyAnimator(duration: 0.24, curve: .easeOut) { [weak self] in
                guard let self else { return }
                self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
            }
            scrollAnimator = animator
            animator.addCompletion { [weak self, weak animator] _ in
                guard let self, self.scrollAnimator === animator else { return }
                self.scrollAnimator = nil
                self.isAutoStickingToBottom = false
                guard !self.isScrollInteractionActive else { return }
                self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
                (self.collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
                self.updateUnreadCountFromVisibility()
                self.updatePillVisibility()
            }
            animator.startAnimation()
        } else {
            UIView.performWithoutAnimation {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.dataSource.apply(snapshot, animatingDifferences: false)
                self.collectionView.layoutIfNeeded()
                if let anchor {
                    self.restore(anchor: anchor)
                }
                CATransaction.commit()
            }
            (collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
            updateUnreadCountFromVisibility()
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

    var bottomRestOffset: CGPoint {
        CGPoint(x: -collectionView.contentInset.left, y: -collectionView.contentInset.top)
    }

    func updateVisualEdgeInsets(preservingBottomPosition: Bool) {
        let oldRestOffset = bottomRestOffset
        let wasNearBottom = distanceFromBottom <= 40
        let safeArea = view.safeAreaInsets
        let mappedInsets = UIEdgeInsets(
            top: 0,
            left: safeArea.left,
            bottom: safeArea.top + keyboardBottomInset,
            right: safeArea.right
        )
        guard collectionView.contentInset != mappedInsets else {
            return
        }
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.collectionView.contentInset = mappedInsets
            self.collectionView.verticalScrollIndicatorInsets = mappedInsets
            CATransaction.commit()
        }
        guard preservingBottomPosition, wasNearBottom, !isScrollInteractionActive else {
            return
        }
        let newRestOffset = bottomRestOffset
        collectionView.contentOffset.x += newRestOffset.x - oldRestOffset.x
        collectionView.contentOffset.y += newRestOffset.y - oldRestOffset.y
    }

    var isScrollInteractionActive: Bool {
        collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
    }

    private static let visualBottomBreathingGap: CGFloat = 8

    func updateCollectionViewportConstraints() {
        guard collectionViewportView != nil else { return }
        let chromeBlock = pixelRounded(bottomChromeHeight + Self.visualBottomBreathingGap)
        collectionViewportBottomConstraint.constant = -chromeBlock
        collectionViewportHeightConstraint.constant = -pixelRounded(view.safeAreaInsets.bottom + chromeBlock)
    }

    func pixelRounded(_ value: CGFloat) -> CGFloat {
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        return (value * scale).rounded() / scale
    }

    private func cancelActiveScrollTransition() {
        scrollAnimator?.stopAnimation(true)
        scrollAnimator = nil
        jumpSnapshotView?.removeFromSuperview()
        jumpSnapshotView = nil
        collectionMotionView?.transform = .identity
        isAutoStickingToBottom = false
    }

    private func flushLatestProjectionForJump(_ completion: @escaping () -> Void) {
        guard let latestInput else {
            completion()
            return
        }
        let projection = projector.project(latestInput, previousRows: currentRows)
        currentRows = projection.rows
        rowsByID = Dictionary(uniqueKeysWithValues: projection.rows.map { ($0.rowID, $0) })
        spacingByID = TranscriptRowSpacing.resolved(for: projection.rows)
        let previousIDs = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(projection.rows.map(\.rowID), toSection: .main)
        let reconfigured = projection.diff.updated.filter(previousIDs.contains)
        if !reconfigured.isEmpty {
            snapshot.reconfigureItems(Array(reconfigured))
        }
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                UIView.performWithoutAnimation {
                    self.collectionView.layoutIfNeeded()
                }
                self.updateUnreadCountFromVisibility()
                self.updatePillVisibility()
                completion()
            }
            CATransaction.commit()
        }
    }

    func updateUnreadCountFromVisibility() {
        guard dataSource != nil else { return }
        let visibleIDs = Set(collectionView.indexPathsForVisibleItems.compactMap {
            dataSource.itemIdentifier(for: $0)
        })
        unreadCount = unreadTracker.unreadCount(rows: currentRows, visibleRowIDs: visibleIDs)
    }

    private func configureScrollEdgeEffects(for collection: UICollectionView) {
        if #available(iOS 26.0, *) {
            // Native edge effects derive their regions from the translated, flipped
            // scroll view and expand across the reading area while the keyboard is up.
            collection.topEdgeEffect.isHidden = true
            collection.bottomEdgeEffect.isHidden = true
        }
        let topMask = TranscriptPinnedTopMaskView()
        topMask.apply(theme: currentTheme)
        topMask.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topMask)
        let bottomMask = TranscriptPinnedBottomMaskView()
        bottomMask.apply(theme: currentTheme)
        bottomMask.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomMask)
        topMaskView = topMask
        bottomMaskView = bottomMask
        NSLayoutConstraint.activate([
            topMask.topAnchor.constraint(equalTo: view.topAnchor),
            topMask.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topMask.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topMask.heightAnchor.constraint(equalToConstant: 56),
            bottomMask.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomMask.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomMask.bottomAnchor.constraint(equalTo: collectionViewportView.bottomAnchor),
            bottomMask.heightAnchor.constraint(equalToConstant: 44),
        ])
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UITEST_CHROME_DEBUG"] == "1" {
            let effectBand = UIView()
            effectBand.translatesAutoresizingMaskIntoConstraints = false
            effectBand.isUserInteractionEnabled = false
            effectBand.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.22)
            effectBand.accessibilityIdentifier = "transcript.chrome.edge-effect-band"
            view.addSubview(effectBand)
            NSLayoutConstraint.activate([
                effectBand.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                effectBand.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                effectBand.bottomAnchor.constraint(equalTo: collectionViewportView.bottomAnchor),
                effectBand.heightAnchor.constraint(equalToConstant: 10),
            ])
        }
        #endif
    }
}

extension TranscriptListViewController: UICollectionViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelActiveScrollTransition()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        (collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
        updateUnreadCountFromVisibility()
        updatePillVisibility()
    }
}
#endif
