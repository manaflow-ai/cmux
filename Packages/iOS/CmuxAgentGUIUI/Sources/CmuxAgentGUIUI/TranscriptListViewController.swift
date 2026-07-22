#if os(iOS)
import CMUXMobileCore
public import CmuxAgentGUIProjection
import CmuxAgentReplica
import SwiftUI
public import UIKit
/// UIKit transcript list with bottom-origin collection layout physics.
@MainActor public final class TranscriptListViewController: UIViewController {
    /// The collection view that owns transcript virtualization and scroll physics.
    public private(set) var collectionView: UICollectionView!
    private let projector = TranscriptProjector()
    var currentTheme: AgentGUITheme
    var dataSource: UICollectionViewDiffableDataSource<TranscriptListSection, TranscriptRowID>!
    var rowsByID: [TranscriptRowID: TranscriptRow] = [:]
    var spacingByID: [TranscriptRowID: TranscriptRowSpacing] = [:]
    var heightCache: [TranscriptRowID: TranscriptRowLayoutCacheEntry] = [:]
    var layoutComputationCount = 0
    var backgroundLayoutComputationCount = 0
    var currentRows: [TranscriptRow] = []
    var currentDensity: TranscriptDensity = .comfortable
    var pendingDensity: TranscriptDensity?
    var isApplyingDensityTransaction = false
    #if DEBUG
    var lastAnchorTrace: (
        capturedScreenTop: CGFloat,
        postLayoutAttributeTop: CGFloat,
        postLayoutVisualTop: CGFloat,
        computedTargetOffset: CGFloat,
        appliedOffset: CGFloat,
        finalScreenTop: CGFloat
    )?
    #endif
    private var latestInput: TranscriptProjectionInput?
    var scrollAnimator: UIViewPropertyAnimator?
    var initialLayoutTask: Task<Void, Never>?
    var initialLayoutGeneration: UInt64 = 0
    var isAutoStickingToBottom = false
    private var jumpSnapshotView: UIView?
    private var collectionViewportView: UIView!
    private var collectionMotionView: UIView!
    private var collectionViewportBottomConstraint: NSLayoutConstraint!
    private var collectionViewportRootBottomConstraint: NSLayoutConstraint!
    private var collectionViewportHeightConstraint: NSLayoutConstraint!
    private var keyboardPinsTranscriptToLayoutGuide = true
    var bottomChromeHeight: CGFloat = 0
    static let nativeBottomEdgeReadabilityClearance: CGFloat = 52
    private var unreadTracker = TranscriptUnreadTracker()
    var pillChromeView: UIView?
    var pillHost: UIHostingController<ScrollToBottomPill>?
    var pillBottomConstraint: NSLayoutConstraint?
    var unreadCount = 0
    var renderedPillUnreadCount = 0
    var bottomEdgeElementContainers: [UIView] = []
    var bottomEdgeInteractions: [any UIInteraction] = []
    weak var topEdgeElementContainer: UIView?
    var topEdgeInteraction: (any UIInteraction)?
    var answeringAskID: String?
    var failedAskID: String?
    var onAnswer: (PendingAsk, Int) -> Void = { _, _ in }
    var onShowTerminal: () -> Void = {}
    var onShowActivity: (TranscriptActivityDetails) -> Void = { _ in }
    /// Creates the transcript list controller.
    public init(theme: AgentGUITheme) {
        currentTheme = theme
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) {
        nil
    }
    deinit {
        MainActor.assumeIsolated {
            initialLayoutTask?.cancel()
            removeScrollEdgeInteractions()
        }
    }
    public override func loadView() {
        view = TranscriptChromePassthroughView()
    }
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        configureCollectionView()
        configureDataSource()
        configurePill()
        registerForTraitChanges([
            UITraitPreferredContentSizeCategory.self,
            UITraitDisplayScale.self,
        ]) { (controller: TranscriptListViewController, _: UITraitCollection) in
            controller.invalidateAllRowLayouts()
        }
    }
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCollectionViewportConstraints()
        updateVisualEdgeInsets(preservingBottomPosition: true)
        reconcileTopEdgeElementContainer()
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
        if dataSource.snapshot().itemIdentifiers.isEmpty,
           projection.rows.count >= 100,
           collectionView.bounds.width > 1 {
            scheduleInitialLayout(for: projection.rows)
            return
        }
        cancelInitialLayout()
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
        view.backgroundColor = .clear
        collectionView.backgroundColor = UIColor(theme.background)
        refreshPillTheme()
        applySnapshot(
            dataSource.snapshot(),
            reconfiguring: Set(dataSource.snapshot().itemIdentifiers),
            anchor: anchor,
            invalidatingLayout: false
        )
    }
    /// Scrolls to the newest transcript row at the bottom-origin layout rest position.
    public func scrollToBottom(animated: Bool = true) {
        cancelActiveScrollTransition()
        if let initialLayoutTask {
            let generation = initialLayoutGeneration
            Task { [weak self] in
                await initialLayoutTask.value
                guard let self, self.initialLayoutGeneration == generation else { return }
                self.performScrollToBottom(animated: animated)
            }
            return
        }
        flushLatestProjectionForJump { [weak self] in
            self?.performScrollToBottom(animated: animated)
        }
    }
    private func performScrollToBottom(animated: Bool) {
        let distance = distanceFromBottom
        guard animated, distance > 0.5 else {
            collectionView.setContentOffset(bottomRestOffset, animated: false)
            updateUnreadCountFromVisibility()
            updatePillVisibility()
            return
        }
        if distance < collectionView.bounds.height * 1.75 {
            animateRealScrollToBottom(duration: 0.45)
            return
        }
        collectionView.layoutIfNeeded()
        guard let oldSnapshot = collectionMotionView.snapshotView(afterScreenUpdates: false) else {
            animateRealScrollToBottom(duration: 0.4)
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
        let animator = UIViewPropertyAnimator(duration: 0.4, curve: .easeOut) { [weak self, weak oldSnapshot] in
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

    private func animateRealScrollToBottom(duration: TimeInterval) {
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) { [weak self] in
            guard let self else { return }
            self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
        }
        scrollAnimator = animator
        animator.addCompletion { [weak self, weak animator] position in
            guard let self, self.scrollAnimator === animator else { return }
            self.scrollAnimator = nil
            guard position == .end else { return }
            self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
            self.updateUnreadCountFromVisibility()
            self.updatePillVisibility()
        }
        animator.startAnimation()
    }

    private func configureCollectionView() {
        let layout = TranscriptCollectionLayout()
        layout.heightForItem = { [weak self] indexPath, width in
            self?.heightForRow(at: indexPath, width: width) ?? 44
        }
        let collection = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = UIColor(currentTheme.background)
        // The bottom-origin layout preserves newest-first projection identity
        // while leaving the scroll view's geometry native. Insets are mapped
        // explicitly so the floating chrome remains the sole obstruction source.
        collection.contentInsetAdjustmentBehavior = .never
        collection.keyboardDismissMode = .interactive
        collection.scrollsToTop = true
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
        viewport.backgroundColor = .clear
        let motionView = UIView()
        motionView.translatesAutoresizingMaskIntoConstraints = false
        motionView.backgroundColor = .clear
        viewport.addSubview(motionView)
        motionView.addSubview(collection)
        view.addSubview(viewport)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        let bottomConstraint = viewport.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor
        )
        let rootBottomConstraint = viewport.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
        collectionViewportRootBottomConstraint = rootBottomConstraint
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
                  let cell
            else {
                return UICollectionViewCell()
            }
            return self.configure(cell: cell, rowID: rowID)
        }
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>()
        snapshot.appendSections([.main])
        applySnapshot(snapshot, reconfiguring: [], anchor: nil, invalidatingLayout: false)
        #if DEBUG
        (collectionView as? TranscriptCollectionView)?.allowsReloadData = false
        #endif
    }

    func configure(
        cell: TranscriptCollectionCell,
        rowID: TranscriptRowID
    ) -> UICollectionViewCell {
        guard let row = rowsByID[rowID],
              let spacing = spacingByID[rowID],
              let layout = layoutForRow(rowID: rowID, width: collectionView.bounds.width)
        else {
            return UICollectionViewCell()
        }
        cell.configure(
            row: row,
            spacing: spacing,
            layout: layout,
            theme: currentTheme,
            answeringAskID: answeringAskID,
            failedAskID: failedAskID,
            onShowActivity: { [weak self] details in self?.onShowActivity(details) },
            onAnswer: onAnswer,
            onShowTerminal: onShowTerminal
        )
        return cell
    }

    func heightForRow(at indexPath: IndexPath, width: CGFloat) -> CGFloat {
        guard currentRows.indices.contains(indexPath.item) else { return 44 }
        let rowID = currentRows[indexPath.item].rowID
        return layoutForRow(rowID: rowID, width: width)?.height ?? 44
    }

    func applyRows(
        _ rows: [TranscriptRow],
        diff: TranscriptProjectionDiff
    ) {
        guard diff.appliedOperationCount > 0 else { return }
        cancelActiveScrollTransition()
        let previousIDs = Set(dataSource.snapshot().itemIdentifiers)
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
        let anchor = mode == .nonAnimatedPreservingAnchor || mode == .animatedIdleAtBottom
            ? captureAnchor()
            : nil
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(rows.map(\.rowID), toSection: .main)
        applySnapshot(
            snapshot,
            reconfiguring: diff.updated,
            anchor: previousIDs.isEmpty ? nil : anchor,
            invalidatingLayout: true
        )
        if previousIDs.isEmpty {
            collectionView.setContentOffset(bottomRestOffset, animated: false)
        }
        if mode == .animatedIdleAtBottom, !previousIDs.isEmpty {
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
        }
        (collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
        updateUnreadCountFromVisibility()
        updatePillVisibility()
    }

    func updateVisualEdgeInsets(preservingBottomPosition: Bool) {
        let oldRestOffset = bottomRestOffset
        let wasNearBottom = distanceFromBottom <= 40
        let safeArea = view.safeAreaInsets
        let mappedInsets = UIEdgeInsets(
            top: safeArea.top,
            left: safeArea.left,
            bottom: safeArea.bottom + Self.nativeBottomEdgeReadabilityClearance,
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
        guard preservingBottomPosition,
              !isApplyingDensityTransaction,
              wasNearBottom,
              !isScrollInteractionActive
        else {
            return
        }
        let newRestOffset = bottomRestOffset
        collectionView.contentOffset.x += newRestOffset.x - oldRestOffset.x
        collectionView.contentOffset.y += newRestOffset.y - oldRestOffset.y
    }

    func updateCollectionViewportConstraints() {
        guard collectionViewportView != nil else { return }
        let baseBottomSafeArea = view.window?.safeAreaInsets.bottom ?? 0
        let keyboardObstruction = view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY
        let keyboardIsDocked = keyboardObstruction > baseBottomSafeArea + 0.5
        if !keyboardIsDocked {
            setKeyboardPinsTranscriptToLayoutGuide(distanceFromBottom <= 0.5)
        }
        collectionViewportBottomConstraint.constant = 0
        collectionViewportHeightConstraint.constant = 0
        (view as? TranscriptChromePassthroughView)?.bottomPassthroughHeight = pixelRounded(
            bottomChromeHeight + (keyboardIsDocked ? 0 : baseBottomSafeArea)
        )
        updatePillBottomConstraint()
    }

    func setKeyboardPinsTranscriptToLayoutGuide(_ pinsToKeyboard: Bool) {
        guard keyboardPinsTranscriptToLayoutGuide != pinsToKeyboard else { return }
        keyboardPinsTranscriptToLayoutGuide = pinsToKeyboard
        collectionViewportBottomConstraint.isActive = false
        collectionViewportRootBottomConstraint.isActive = false
        if pinsToKeyboard {
            collectionViewportBottomConstraint.isActive = true
        } else {
            collectionViewportRootBottomConstraint.isActive = true
        }
        view.setNeedsLayout()
    }

    func pixelRounded(_ value: CGFloat) -> CGFloat {
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        return (value * scale).rounded() / scale
    }

    func cancelActiveScrollTransition() {
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
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptListSection, TranscriptRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(projection.rows.map(\.rowID), toSection: .main)
        applySnapshot(
            snapshot,
            reconfiguring: projection.diff.updated,
            anchor: nil,
            invalidatingLayout: projection.diff.appliedOperationCount > 0
        )
        updateUnreadCountFromVisibility()
        updatePillVisibility()
        completion()
    }

    func updateUnreadCountFromVisibility() {
        guard dataSource != nil else { return }
        let visibleIDs = Set(collectionView.indexPathsForVisibleItems.compactMap {
            dataSource.itemIdentifier(for: $0)
        })
        unreadCount = unreadTracker.unreadCount(rows: currentRows, visibleRowIDs: visibleIDs)
    }

}

extension TranscriptListViewController: UICollectionViewDelegate {
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelActiveScrollTransition()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let baseBottomSafeArea = view.window?.safeAreaInsets.bottom ?? 0
        let keyboardObstruction = view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY
        if keyboardObstruction <= baseBottomSafeArea + 0.5 {
            setKeyboardPinsTranscriptToLayoutGuide(distanceFromBottom <= 0.5)
        }
        (collectionView as? TranscriptCollectionView)?.updateAccessibilityOrder()
        updateUnreadCountFromVisibility()
        updatePillVisibility()
    }

}
#endif
