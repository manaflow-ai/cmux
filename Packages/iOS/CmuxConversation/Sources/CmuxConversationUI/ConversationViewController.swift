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
    private(set) lazy var collectionView = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
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
    /// The incoming message replacing a typing indicator in the current change.
    var typingHandoffRowID: String?
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
    /// A row kept visible above the composer as insets change (the message
    /// being edited stays in view when the keyboard rises).
    var revealRowID: String?
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
        // Resting on the newest message counts as following it, whatever the
        // flag says (an interactive keyboard dismissal drags the content away
        // from the bottom mid-gesture, then settles back onto it).
        if !collectionView.isTracking, !collectionView.isDecelerating, hasPositionedInitially, isNearBottom(tolerance: 2) {
            isPinnedToBottom = true
        }
        // A reader pinned to the bottom stays pinned as the keyboard, drawer or
        // composer changes the inset; a reader scrolled up stays where they are.
        collectionView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        collectionView.edgeBottomInset = bottom
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if old.top != top { layout.invalidateLayout() }
        if !collectionView.isTracking, hasPositionedInitially {
            if isPinnedToBottom {
                collectionView.contentOffset = bottomOffset
            } else {
                var offset = collectionView.contentOffset
                if let id = revealRowID, let index = rowIndex[id], let frame = layout.frame(at: index) {
                    offset.y = max(offset.y, frame.maxY + bottom - collectionView.bounds.height)
                }
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
            case .typing: arrivingRowIDs.append(id)
            case .loadingOlder: appearances[id] = .fade
            default: break
            }
        }

        // A typing indicator replaced by the message it announced vanishes at
        // once: the message grows in its place, so a fading indicator (with its
        // own avatar) would double the sender for a few frames.
        let replacesTyping = inserted.contains { indexPath in
            if case .message = newRows[indexPath.item] { return true } else { return false }
        }
        var removedTyping = false
        if animateLive, replacesTyping {
            for indexPath in deleted where indexPath.item < rows.count {
                if case .typing = rows[indexPath.item], let cell = collectionView.cellForItem(at: indexPath) {
                    UIView.performWithoutAnimation { cell.contentView.alpha = 0 }
                    removedTyping = true
                }
            }
        }
        // The message that takes the indicator's place shows at full opacity
        // from the first frame, so the hand-off never passes through an empty frame.
        if removedTyping, let handoff = inserted.last(where: { indexPath in
            if case let .message(model) = newRows[indexPath.item] { return !model.isOutgoing } else { return false }
        }) {
            typingHandoffRowID = newIDs[handoff.item]
        }
        // Non-animated changes (a page landing) can regroup visible rows
        // (spacing, tail, sender name); rows that move a few points glide.
        let screenBefore = animateLive ? [:] : visibleScreenTops()

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
        let startOffsetY = collectionView.contentOffset.y
        var scrollShift: CGFloat = 0
        if animateLive, wasAtBottom || sentByMe {
            // Pinned: insertions and the scroll to the new bottom share one spring.
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.collectionView.performBatchUpdates(updates)
                if structural, !updated.isEmpty { self.collectionView.reconfigureItems(at: updated) }
                self.collectionView.layoutIfNeeded()
                self.collectionView.contentOffset = self.bottomOffset
            }
            scrollShift = collectionView.contentOffset.y - startOffsetY
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
            glideRegrouped(from: screenBefore)
        }
        appearances = appearances.filter { flyingRowIDs.contains($0.key) }
        popArrivals(scrollShift: scrollShift)
    }

    private struct ScreenPlace { var rowTop: CGFloat; var bubbleTop: CGFloat }

    private func visibleScreenTops() -> [String: ScreenPlace] {
        var places: [String: ScreenPlace] = [:]
        let y = collectionView.contentOffset.y
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.item < rows.count {
            guard let frame = layout.frame(at: indexPath.item) else { continue }
            let bubble = bubbleTop(at: indexPath.item) ?? frame.minY
            places[rows[indexPath.item].id] = ScreenPlace(rowTop: frame.minY - y, bubbleTop: bubble - y)
        }
        return places
    }

    /// Rows that a non-animated change moved on screen (for example rows below
    /// an anchor whose run grouping or quote changed when an older page landed)
    /// start at their old place and glide, instead of stepping. A row glides
    /// only by the movement its top and its bubble share: the anchor (bubble
    /// held, row grew above it) and a row that grew inside itself stay put, so
    /// no glide pushes new content over its neighbors.
    private func glideRegrouped(from before: [String: ScreenPlace]) {
        guard !before.isEmpty else { return }
        let after = visibleScreenTops()
        #if DEBUG
        var moved: [String] = []
        #endif
        for (id, place) in after {
            guard let old = before[id], let indexPath = indexPath(for: id),
                  let cell = collectionView.cellForItem(at: indexPath) else { continue }
            let rowDelta = place.rowTop - old.rowTop
            let bubbleDelta = place.bubbleTop - old.bubbleTop
            let shared = rowDelta * bubbleDelta <= 0 ? 0 : (abs(rowDelta) < abs(bubbleDelta) ? rowDelta : bubbleDelta)
            guard abs(shared) >= 0.5, abs(shared) <= 120 else { continue }
            #if DEBUG
            moved.append(String(format: "%.1f", shared))
            #endif
            UIView.performWithoutAnimation {
                cell.contentView.transform = CGAffineTransform(translationX: 0, y: -shared)
            }
            UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                cell.contentView.transform = .identity
            }
        }
        #if DEBUG
        NSLog("imsgp.glide before=%d after=%d moved=%@", before.count, after.count, moved.joined(separator: ","))
        #endif
    }

    /// New incoming bubbles (and the typing indicator) appear at their final
    /// place on screen, scaling from 0.8 at their tail corner with a fade
    /// (Messages, criterion 8.1). Rows above move up by `scrollShift` on the
    /// same spring; each new bubble is masked to the space those rows have
    /// already vacated, so nothing overlaps in any frame and nothing slides up
    /// from behind the composer. Bursts reveal bottom-up as one region.
    private func popArrivals(scrollShift: CGFloat) {
        let ids = arrivingRowIDs
        arrivingRowIDs = []
        let handoff = typingHandoffRowID
        typingHandoffRowID = nil
        let items = ids.compactMap { indexPath(for: $0)?.item }.sorted()
        var runs: [[Int]] = []
        for item in items {
            if let last = runs.last?.last, last + 1 == item {
                runs[runs.count - 1].append(item)
            } else {
                runs.append([item])
            }
        }
        let startScale: CGFloat = 0.8
        let shift = max(0, scrollShift)
        for run in runs {
            guard let runTop = run.compactMap({ layout.frame(at: $0)?.minY }).min() else { continue }
            for item in run {
                guard let cell = collectionView.cellForItem(at: IndexPath(item: item, section: 0)),
                      let frame = layout.frame(at: item) else { continue }
                let size = frame.size
                var pivot = CGPoint(x: 0, y: size.height)
                if let cell = cell as? MessageCell, let content = cell.cellLayout?.contentFrame {
                    pivot = CGPoint(x: content.minX, y: content.maxY)
                } else if let cell = cell as? TypingCell {
                    pivot = CGPoint(x: cell.indicator.frame.minX, y: cell.indicator.frame.maxY)
                }
                let tx = (1 - startScale) * (pivot.x - size.width / 2)
                let ty = (1 - startScale) * (pivot.y - size.height / 2) - shift
                // Local y above which the cell is still covered by the rows
                // moving up; it reaches the run top (<= 0 here) as they finish.
                let coveredStart = runTop - frame.minY + shift
                let coveredEnd = runTop - frame.minY
                let maskHeight = size.height * 4 + 2 * shift
                let mask = ArrivalRevealMask(frame: CGRect(x: -size.width, y: coveredStart, width: size.width * 3, height: maskHeight))
                let isHandoff = rows[item].id == handoff
                UIView.performWithoutAnimation {
                    cell.contentView.mask = shift > 0 ? mask : nil
                    cell.contentView.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: startScale, y: startScale)
                    cell.contentView.alpha = isHandoff ? 1 : 0
                }
                // The same spring as the scroll, so reveal and scroll share progress.
                UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    cell.contentView.transform = .identity
                    mask.frame.origin.y = coveredEnd
                } completion: { _ in
                    if cell.contentView.mask === mask { cell.contentView.mask = nil }
                }
                if !isHandoff {
                    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                        cell.contentView.alpha = 1
                    }
                }
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

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { isPinnedToBottom = isNearBottom(tolerance: 44) }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isPinnedToBottom = isNearBottom(tolerance: 44)
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

/// The transcript reports the composer band (and keyboard) as its bottom
/// safe area, so the system bottom scroll edge effect covers the composer
/// wherever it sits instead of the screen edge behind the keyboard. Content
/// insets are managed by hand (adjustment is off), so this changes nothing else.
final class TranscriptCollectionView: UICollectionView {
    var edgeBottomInset: CGFloat = 0 {
        didSet { if edgeBottomInset != oldValue { safeAreaInsetsDidChange() } }
    }

    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.bottom = max(insets.bottom, edgeBottomInset)
        return insets
    }
}

/// The arrival reveal edge: opaque below, with a short feather at its top so
/// the edge that follows the rows moving up never reads as a hard cut.
final class ArrivalRevealMask: UIView {
    static let feather: CGFloat = 10

    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        updateStops()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateStops()
    }

    private func updateStops() {
        let edge = bounds.height > 0 ? Self.feather / bounds.height : 0
        (layer as! CAGradientLayer).locations = [0, NSNumber(value: Double(edge)), 1]
    }
}
#endif
