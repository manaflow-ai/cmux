#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Host-provided presentation details.
public struct ConversationPresentationOptions {
    public var placeholder: String?
    public var serviceTitle: String
    public var serviceSubtitle: String
    public var unreadCount: Int
    public var trailingSymbol: String

    public init(
        placeholder: String? = nil,
        serviceTitle: String = "iMessage",
        serviceSubtitle: String? = nil,
        unreadCount: Int = 0,
        trailingSymbol: String = "video"
    ) {
        self.placeholder = placeholder
        self.serviceTitle = serviceTitle
        self.serviceSubtitle = serviceSubtitle ?? String(localized: "conversation.start.encrypted", defaultValue: "Encrypted", bundle: .module)
        self.unreadCount = unreadCount
        self.trailingSymbol = trailingSymbol
    }
}

/// A Messages-style conversation over any `ConversationBackend`.
public final class ConversationViewController: UIViewController {
    public let store: ConversationStore
    public var onBack: (() -> Void)?
    let options: ConversationPresentationOptions

    let layout = ConversationTranscriptLayout()
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    let header = ConversationHeaderView()
    let composer = ConversationComposerView()
    let composerContainer = UIView()
    var composerHeightConstraint: NSLayoutConstraint?
    /// Set while `composerDidTapSend` inserts the optimistic row.
    var pendingFlight: SendFlight?
    var composerBottomConstraint: NSLayoutConstraint?
    /// Shown until the newest page arrives (slow links can take seconds).
    let initialSpinner = UIActivityIndicatorView(style: .medium)
    lazy var cameraDelegate: ConversationMediaDelegate = {
        let delegate = ConversationMediaDelegate()
        delegate.controller = self
        return delegate
    }()
    let layoutCache = MessageLayoutCache()

    private(set) var rows: [ConversationRow] = []
    private var rowIndex: [String: Int] = [:]
    /// Rows whose insertion should use a specific appearance on the next update.
    var appearances: [String: ConversationTranscriptLayout.Appearance] = [:]
    /// Outgoing rows hidden while their send animation flies.
    var flyingRowIDs: Set<String> = []
    /// Overlay views of in-flight sends, keyed by row.
    var activeFlights: [String: UIView] = [:]
    /// Incoming rows inserted by the current update, popped in after it applies.
    var arrivingRowIDs: [String] = []
    private var hasPositionedInitially = false
    private var lastBottomInset: CGFloat = 0
    /// Whether the reader is following the bottom. Only the reader's own
    /// scrolling (or a send) changes it; inset changes never do.
    var isPinnedToBottom = true
    var layoutMargin: CGFloat { view.directionalLayoutMargins.leading }

    // Interaction state (see +Gestures).
    var timestampReveal: CGFloat = 0
    var replyDragRowID: String?
    var replyDragOffset: CGFloat = 0
    var replyHapticFired = false
    var replyTarget: ConversationMessage?
    var editingMessageID: String?
    var isSelecting = false
    var selectedRowIDs: Set<String> = []
    var photoDrawer: ConversationPhotoGridView?
    var pickedAssets: [String: UUID] = [:]
    var drawerHeightConstraint: NSLayoutConstraint?

    public init(store: ConversationStore, options: ConversationPresentationOptions = ConversationPresentationOptions()) {
        self.store = store
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ConversationTheme.background

        layout.dataSource = self
        collectionView.backgroundColor = ConversationTheme.background
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuseID)
        collectionView.register(TimestampCell.self, forCellWithReuseIdentifier: TimestampCell.reuseID)
        collectionView.register(LoadingCell.self, forCellWithReuseIdentifier: LoadingCell.reuseID)
        collectionView.register(ConversationStartCell.self, forCellWithReuseIdentifier: ConversationStartCell.reuseID)
        collectionView.register(TypingCell.self, forCellWithReuseIdentifier: TypingCell.reuseID)
        collectionView.accessibilityIdentifier = "conversation.transcript"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerContainer)
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.delegate = self
        if let placeholder = options.placeholder { composer.placeholderText = placeholder }
        composerContainer.addSubview(composer)

        header.translatesAutoresizingMaskIntoConstraints = false
        header.trailingSymbol = options.trailingSymbol
        header.setTrailingMode(.action, animated: false)
        header.onBack = { [weak self] in self?.handleBack() }
        header.onInfo = { [weak self] in self?.openInfo() }
        header.onTrailing = { [weak self] in self?.handleHeaderTrailing() }
        view.addSubview(header)

        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        let composerHeight = composer.heightAnchor.constraint(equalToConstant: composer.preferredHeight)
        composerHeightConstraint = composerHeight
        let composerBottom = composerContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -4)
        composerBottomConstraint = composerBottom
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: ConversationHeaderView.contentHeight),
            composerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBottom,
            composer.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
            composerHeight,
        ])

        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.style = .soft
            collectionView.bottomEdgeEffect.style = .soft
            let top = UIScrollEdgeElementContainerInteraction()
            top.scrollView = collectionView
            top.edge = .top
            header.addInteraction(top)
            let bottom = UIScrollEdgeElementContainerInteraction()
            bottom.scrollView = collectionView
            bottom.edge = .bottom
            composerContainer.addInteraction(bottom)
        }

        installGestures()
        initialSpinner.translatesAutoresizingMaskIntoConstraints = false
        initialSpinner.startAnimating()
        initialSpinner.accessibilityIdentifier = "conversation.initialLoading"
        view.insertSubview(initialSpinner, belowSubview: header)
        NSLayoutConstraint.activate([
            initialSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            initialSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPhotoDrawer() }
        }
        store.onChange = { [weak self] change in self?.storeDidChange(change) }
        store.start()
        rebuild(change: .reset)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateInsets()
        let available = composerContainer.frame.maxY - header.frame.maxY - 8
        composer.maximumFieldHeight = max(ConversationTheme.composerMinHeight, available - 8)
        layoutReplyOverlay()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            layoutCache.invalidateAll()
            collectionView.reloadData()
        }
    }

    // MARK: Insets

    /// Keeps the last message directly above the composer and the first below
    /// the header. When the bottom inset changes (keyboard, composer growth)
    /// the visible content moves with it, unless the finger is driving.
    func updateInsets() {
        let top = header.frame.maxY + 4
        let bottom = max(0, view.bounds.maxY - composerContainer.frame.minY) + 10
        let old = collectionView.contentInset
        guard old.top != top || old.bottom != bottom else { return }
        // A reader pinned to the bottom stays pinned as the keyboard, drawer or
        // composer changes the inset; a reader scrolled up stays where they are.
        collectionView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if old.top != top { layout.invalidateLayout() }
        if !collectionView.isTracking, hasPositionedInitially {
            if isPinnedToBottom {
                collectionView.contentOffset = bottomOffset
            } else {
                var offset = collectionView.contentOffset
                offset.y = min(max(-top, offset.y), bottomOffset.y)
                collectionView.contentOffset = offset
            }
        }
        lastBottomInset = bottom
    }

    var bottomOffset: CGPoint {
        let inset = collectionView.adjustedContentInset
        let y = max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        return CGPoint(x: 0, y: y)
    }

    func isNearBottom(tolerance: CGFloat = 44) -> Bool {
        collectionView.contentOffset.y >= bottomOffset.y - tolerance
    }

    // MARK: Rows

    private func storeDidChange(_ change: ConversationStoreChange) {
        switch change {
        case .connection:
            header.setConnectionStatus(store.connection == .connected ? nil : String(localized: "conversation.header.connecting", defaultValue: "Connecting…", bundle: .module))
            if let info = store.info { header.configure(info: info, meID: store.meID, unreadCount: options.unreadCount) }
            return
        default:
            rebuild(change: change)
        }
    }

    func rebuild(change: ConversationStoreChange) {
        if store.hasLoadedNewest, initialSpinner.isAnimating {
            initialSpinner.stopAnimating()
            initialSpinner.isHidden = true
        }
        let newRows = ConversationRowBuilder.rows(store: store)
        apply(newRows, change: change)
        if let info = store.info, header.window != nil, !hasConfiguredHeader {
            hasConfiguredHeader = true
            header.configure(info: info, meID: store.meID, unreadCount: options.unreadCount)
        }
        maybeLoadOlder()
    }

    private var hasConfiguredHeader = false

    private struct Anchor {
        var rowID: String
        var offsetFromTop: CGFloat
    }

    /// The anchor is the bubble, not the row: a row can gain or lose its
    /// sender name or reply quote when neighbors change (for example when an
    /// older page joins it to a run), and the bubble must not move.
    private func bubbleTop(at index: Int) -> CGFloat? {
        guard index < rows.count, case let .message(model) = rows[index], let frame = layout.frame(at: index) else { return nil }
        let content = layoutCache.layout(for: model, width: collectionView.bounds.width, margin: layoutMargin).contentFrame
        return frame.minY + content.minY
    }

    private func captureAnchor() -> Anchor? {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let candidates = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        for indexPath in candidates {
            guard indexPath.item < rows.count, let frame = layout.frame(at: indexPath.item),
                  case .message = rows[indexPath.item], frame.maxY > top,
                  let bubbleTop = bubbleTop(at: indexPath.item) else { continue }
            return Anchor(rowID: rows[indexPath.item].id, offsetFromTop: bubbleTop - collectionView.contentOffset.y)
        }
        return nil
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, let index = rowIndex[anchor.rowID], let bubbleTop = bubbleTop(at: index) else { return }
        var offset = collectionView.contentOffset
        offset.y = bubbleTop - anchor.offsetFromTop
        collectionView.contentOffset = offset
    }

    private func apply(_ newRows: [ConversationRow], change: ConversationStoreChange) {
        let oldIDs = rows.map(\.id)
        let newIDs = newRows.map(\.id)
        let oldIndex = rowIndex
        var newIndex: [String: Int] = [:]
        newIndex.reserveCapacity(newIDs.count)
        for (index, id) in newIDs.enumerated() { newIndex[id] = index }

        // Before anything is shown, or when the whole window changed, reload.
        if !hasPositionedInitially || change == .reset && oldIDs.isEmpty {
            rows = newRows
            rowIndex = newIndex
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            if !newRows.isEmpty {
                collectionView.contentOffset = bottomOffset
                hasPositionedInitially = true
            }
            return
        }

        let deleted = oldIDs.enumerated().compactMap { newIndex[$0.element] == nil ? IndexPath(item: $0.offset, section: 0) : nil }
        let inserted = newIDs.enumerated().compactMap { oldIndex[$0.element] == nil ? IndexPath(item: $0.offset, section: 0) : nil }
        let commonOld = oldIDs.filter { newIndex[$0] != nil }
        let commonNew = newIDs.filter { oldIndex[$0] != nil }
        // Changed rows are refreshed after the structural batch applies, with
        // post-update paths: inside a batch, reconfigure would dequeue against
        // the new data at a pre-update path and hit a different row kind.
        var updated: [IndexPath] = []
        if commonOld == commonNew {
            for id in commonNew {
                guard let o = oldIndex[id], let n = newIndex[id], rows[o] != newRows[n] else { continue }
                updated.append(IndexPath(item: n, section: 0))
            }
        }
        let structural = commonOld == commonNew

        // A failed send reshapes its row; never leave its flight hanging.
        for indexPath in updated {
            if case let .message(model) = newRows[indexPath.item], model.footer == .notDelivered {
                landFlight(rowID: model.rowID)
            }
        }
        let wasAtBottom = isPinnedToBottom || isNearBottom()
        let anchor = captureAnchor()
        if sentByMeChange(change) { isPinnedToBottom = true }
        // Scroll-to-bottom applies only to a new row I just sent from here.
        let sentByMe = sentByMeChange(change)
        let animateLive: Bool = {
            switch change {
            case .live, .typing: return true
            default: return false
            }
        }()

        for indexPath in inserted {
            let id = newIDs[indexPath.item]
            guard appearances[id] == nil else { continue }
            switch newRows[indexPath.item] {
            case let .message(model) where model.isOutgoing && pendingFlight != nil:
                appearances[id] = .sent
                flyingRowIDs.insert(id)
            case let .message(model) where !model.isOutgoing && animateLive: arrivingRowIDs.append(model.rowID)
            case .typing: appearances[id] = .incoming
            case .loadingOlder: appearances[id] = .fade
            default: break
            }
        }

        let updates = {
            self.rows = newRows
            self.rowIndex = newIndex
            if structural {
                self.collectionView.deleteItems(at: deleted)
                self.collectionView.insertItems(at: inserted)
            } else {
                self.collectionView.reloadSections(IndexSet(integer: 0))
            }
        }

        if animateLive, sentByMe, !wasAtBottom {
            // Far from the bottom, jump there first so the send never animates
            // through unloaded history (which would flash blank frames).
            UIView.performWithoutAnimation {
                self.collectionView.contentOffset = self.bottomOffset
                self.collectionView.layoutIfNeeded()
            }
        }
        if animateLive, wasAtBottom || sentByMe {
            // Pinned: insertions and the scroll to the new bottom share one spring.
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.collectionView.performBatchUpdates(updates)
                if structural, !updated.isEmpty { self.collectionView.reconfigureItems(at: updated) }
                self.collectionView.layoutIfNeeded()
                self.collectionView.contentOffset = self.bottomOffset
            }
        } else if animateLive {
            // Away from bottom: animate in place, keep the reader's anchor fixed.
            UIView.animate(withDuration: 0.3, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.collectionView.performBatchUpdates(updates)
                if structural, !updated.isEmpty { self.collectionView.reconfigureItems(at: updated) }
                self.collectionView.layoutIfNeeded()
                self.restore(anchor)
            }
        } else {
            UIView.performWithoutAnimation {
                self.collectionView.performBatchUpdates(updates)
                if structural, !updated.isEmpty { self.collectionView.reconfigureItems(at: updated) }
                self.collectionView.layoutIfNeeded()
                self.restore(anchor)
            }
        }
        appearances = appearances.filter { flyingRowIDs.contains($0.key) }
        popArrivals()
    }

    /// New incoming bubbles grow from their tail corner with a short spring
    /// (Messages' arrival), driven on the cell so the scroll can't flatten it.
    private func popArrivals() {
        let ids = arrivingRowIDs
        arrivingRowIDs = []
        for id in ids {
            guard let indexPath = indexPath(for: id), let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
                  let content = cell.cellLayout?.contentFrame else { continue }
            let pivot = CGPoint(x: content.minX, y: content.maxY)
            let center = CGPoint(x: cell.shiftable.bounds.midX, y: cell.shiftable.bounds.midY)
            let scale: CGFloat = 0.75
            let start = CGAffineTransform(translationX: (pivot.x - center.x) * (1 - scale), y: (pivot.y - center.y) * (1 - scale)).scaledBy(x: scale, y: scale)
            UIView.performWithoutAnimation {
                cell.shiftable.transform = start
                cell.shiftable.alpha = 0
            }
            UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                cell.shiftable.transform = .identity
                cell.shiftable.alpha = 1
            }
        }
    }

    private func sentByMeChange(_ change: ConversationStoreChange) -> Bool {
        if case let .live(inserted, mine) = change { return mine && !inserted.isEmpty }
        return false
    }

    func maybeLoadOlder() {
        guard hasPositionedInitially, store.hasLoadedNewest else { return }
        let fromTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let viewport = collectionView.bounds.height
        if fromTop < viewport * 1.5 {
            store.loadOlder()
        } else if fromTop > viewport * 3 {
            store.olderNoLongerWanted()
        }
    }

    func row(for rowID: String) -> ConversationRow? {
        rowIndex[rowID].map { rows[$0] }
    }

    func indexPath(for rowID: String) -> IndexPath? {
        rowIndex[rowID].map { IndexPath(item: $0, section: 0) }
    }

    // MARK: Header actions

    private func handleBack() {
        if let onBack {
            onBack()
        } else if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func handleHeaderTrailing() {
        if editingMessageID != nil {
            exitEditMode()
        } else if isSelecting {
            setSelecting(false)
        } else if replyTarget != nil {
            exitReplyMode()
        }
    }

    func openInfo() {
        guard let info = store.info else { return }
        let controller = ConversationInfoViewController(info: info, meID: store.meID)
        if let navigationController {
            navigationController.setNavigationBarHidden(false, animated: true)
            navigationController.pushViewController(controller, animated: true)
        } else {
            present(UINavigationController(rootViewController: controller), animated: true)
        }
    }
}

// MARK: - Data source

extension ConversationViewController: UICollectionViewDataSource, UICollectionViewDelegate, ConversationTranscriptLayoutDataSource {
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.count
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch rows[indexPath.item] {
        case let .message(model):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
            let cellLayout = layoutCache.layout(for: model, width: collectionView.bounds.width, margin: layoutMargin)
            cell.configure(model: model, layout: cellLayout, text: layoutCache.attributedText(for: model))
            cell.contentView.alpha = flyingRowIDs.contains(model.rowID) ? 0 : 1
            cell.timestampReveal = timestampReveal
            cell.setSelectionMode(isSelecting, selected: selectedRowIDs.contains(model.rowID), animated: false)
            cell.accessibilityIdentifier = "conversation.message.\(model.message.id)"
            return cell
        case let .timestamp(_, date):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TimestampCell.reuseID, for: indexPath) as! TimestampCell
            cell.configure(date: date)
            return cell
        case .loadingOlder:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LoadingCell.reuseID, for: indexPath) as! LoadingCell
            cell.configure(active: true)
            return cell
        case .conversationStart:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ConversationStartCell.reuseID, for: indexPath) as! ConversationStartCell
            cell.configure(title: options.serviceTitle, subtitle: options.serviceSubtitle)
            return cell
        case let .typing(ids):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TypingCell.reuseID, for: indexPath) as! TypingCell
            cell.margin = layoutMargin
            // Batch updates and reuse strip layer animations; restart the pulse.
            cell.indicator.startAnimating()
            let participant = ids.first.flatMap { store.info?.participant($0) }
            cell.configure(
                initials: participant?.initials,
                showsAvatar: store.info?.kind == .group,
                accessibilityName: ids.compactMap { store.info?.participant($0)?.name }.joined(separator: ", ")
            )
            return cell
        }
    }

    public func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        // A status-bar tap leaves the bottom on purpose.
        isPinnedToBottom = false
        return true
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A flight is pinned to the screen; once the reader scrolls, show the real row.
        landAllFlights()
        dismissPhotoDrawer()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isTracking || scrollView.isDecelerating {
            isPinnedToBottom = isNearBottom(tolerance: 44)
        }
        maybeLoadOlder()
        if store.hasLoadedNewest, isNearBottom(tolerance: 60) {
            store.markNewestRead()
        }
    }

    public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? TypingCell)?.indicator.startAnimating()
    }

    func transcriptItemCount() -> Int { rows.count }

    func transcriptHeight(at index: Int, width: CGFloat) -> CGFloat {
        switch rows[index] {
        case let .message(model):
            return layoutCache.layout(for: model, width: width, margin: layoutMargin).height
        case .timestamp: return TimestampCell.height
        case .loadingOlder: return LoadingCell.height
        case .conversationStart: return ConversationStartCell.height
        case .typing: return TypingCell.height(isGroup: store.info?.kind == .group)
        }
    }

    func transcriptSpacing(before index: Int) -> CGFloat {
        guard case let .message(model) = rows[index] else {
            if case .typing = rows[index], index > 0, case let .message(previous) = rows[index - 1],
               let typer = store.typingParticipantIDs.first, previous.message.senderID == typer {
                return ConversationTheme.groupedSpacing
            }
            return index > 0 && isMessage(index - 1) ? 10 : 0
        }
        guard index > 0, isMessage(index - 1) else { return 4 }
        return model.isFirstInGroup ? ConversationTheme.ungroupedSpacing : ConversationTheme.groupedSpacing
    }

    private func isMessage(_ index: Int) -> Bool {
        if case .message = rows[index] { return true }
        return false
    }

    func transcriptAppearance(at index: Int) -> ConversationTranscriptLayout.Appearance {
        appearances[rows[index].id] ?? .none
    }
}
#endif
