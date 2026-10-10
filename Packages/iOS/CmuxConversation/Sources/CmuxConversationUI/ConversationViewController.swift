#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import GameController
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
    /// Select mode's Forward button. The host presents New Message prefilled
    /// with the draft; when unset, a minimal placeholder sheet stands in.
    public var onForward: ((ConversationForwardDraft) -> Void)?
    let options: ConversationPresentationOptions

    let layout = ConversationTranscriptLayout()
    private(set) lazy var collectionView = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
    let header = ConversationHeaderView()
    let topEdgeFade = ConversationTopEdgeFade()
    /// The conversation background, behind the transcript (see +Background).
    let backdropView = ConversationBackdropView()
    var detailsOverlay: ConversationDetailsOverlay?
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
    let audioPlayer = ConversationAudioPlayer()
    lazy var audioComposer = ConversationAudioComposer(controller: self)

    private(set) var rows: [ConversationRow] = []
    private(set) var rowIndex: [String: Int] = [:]
    /// `rows.map(\.id)`, kept so each update does not walk the old row models.
    private var rowIDs: [String] = []
    /// Height and leading spacing of each row, aligned with `rows` (NaN = not
    /// measured), valid for `rowMetricsKey`. An update re-measures only the
    /// rows it inserts or changes (and their followers' spacing), so a layout
    /// pass over a long transcript is a sum instead of a walk over row models.
    private var rowMetrics: [RowMetrics] = []
    private var rowMetricsKey: (width: CGFloat, margin: CGFloat) = (0, 0)
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
    /// The typer's avatar (frame in the transcript, initials) leaving with the indicator.
    var typingAvatarHandoff: (frame: CGRect, initials: String)?
    private(set) var hasPositionedInitially = false
    /// The catch-up arrow (see +CatchUp).
    let catchUpButton = UIButton(type: .custom)
    /// Between viewDidAppear and viewWillDisappear.
    var isOnScreen = false
    /// Live back-button count set by the host; overrides `options.unreadCount`.
    var backUnreadCount: Int?
    private var headerUnreadCount: Int { backUnreadCount ?? options.unreadCount }
    private var lastBottomInset: CGFloat = 0
    /// Whether the reader is following the bottom. Only the reader's own
    /// scrolling (or a send) changes it; inset changes never do.
    var isPinnedToBottom = true
    /// A status-bar tap's animated scroll to the top is running. Messages
    /// loads history only once it comes to rest at the spinner, so a page
    /// never lands under (and is never chased by) that animation.
    var isScrollingToTop = false
    var layoutMargin: CGFloat { view.directionalLayoutMargins.leading }

    // Interaction state (see +Gestures).
    var timestampReveal: CGFloat = 0
    /// How far outgoing bubbles travel at a full swipe-left reveal.
    var timestampRevealDistance: CGFloat = 58
    /// Swipe-left send times (see +TimestampDrawer).
    var timestampDrawer = TimestampDrawerPhysics(maxOffset: 58)
    var timestampDrawerEnabled = false
    var timestampDrawerRelease: TimestampDrawerPhysics.Release?
    var timestampDrawerReleaseStart: CFTimeInterval?
    var timestampDrawerLink: CADisplayLink?
    var replyDragRowID: String?
    var replyDragOffset: CGFloat = 0
    var replyHapticFired = false
    var replyTarget: ConversationMessage?
    var editingMessageID: String?
    /// The in-place editor while a message is being edited.
    var editOverlay: MessageEditOverlay?
    /// A row kept visible above the composer as insets change (the message
    /// being edited stays in view when the keyboard rises).
    var revealRowID: String?
    var isSelecting = false
    var selectedRowIDs: Set<String> = []
    /// The long-press menu's "Select": in-bubble text selection, if active.
    var textSelection: BubbleTextSelectionView?
    var photoDrawer: ConversationPhotoGridView?
    var pickedAssets: [String: UUID] = [:]
    var drawerHeightConstraint: NSLayoutConstraint?
    /// Keyboard-relative base line of the composer (see `composerBottomConstraint`).
    let composerBase = UILayoutGuide()
    var composerDropConstraint: NSLayoutConstraint?
    /// Height of the docked keyboard when fully shown, from its notifications.
    var dockedKeyboardHeight: CGFloat = 0
    /// Top edge of the keyboard's latest end frame, in view coordinates.
    var keyboardEndTop: CGFloat = .greatestFiniteMagnitude
    /// The composer's bottom edge after the last keyboard-following pass.
    var lastComposerBottom: CGFloat = 0
    /// A rotation or resize is under way (iOS 27 hides and reshows the
    /// keyboard around one).
    private var isTransitioningSize = false
    var effects = ConversationEffectsState()

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
        collectionView.register(SendLaterHeaderCell.self, forCellWithReuseIdentifier: SendLaterHeaderCell.reuseID)
        store.onScheduledActionFailed = { [weak self] in self?.presentScheduledActionFailure($0) }
        collectionView.register(SystemEventCell.self, forCellWithReuseIdentifier: SystemEventCell.reuseID)
        collectionView.register(UnavailabilityCell.self, forCellWithReuseIdentifier: UnavailabilityCell.reuseID)
        collectionView.accessibilityIdentifier = "conversation.transcript"
        collectionView.accessibilityLabel = ConversationAccessibilityText.transcript
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerContainer)
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.delegate = self
        composer.linkPreview.fetch = { [weak store] url in await store?.fetchLinkPreview(for: url) }
        if let placeholder = options.placeholder { composer.placeholderText = placeholder }
        composerContainer.addSubview(composer)

        header.translatesAutoresizingMaskIntoConstraints = false
        header.trailingSymbol = options.trailingSymbol
        header.setTrailingMode(.action, animated: false)
        header.onBack = { [weak self] in self?.handleBack() }
        header.onInfo = { [weak self] in self?.openInfo() }
        header.onTrailing = { [weak self] in self?.handleHeaderTrailing() }
        topEdgeFade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topEdgeFade)
        view.addSubview(header)

        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        let composerHeight = composer.heightAnchor.constraint(equalToConstant: composer.preferredHeight)
        composerHeightConstraint = composerHeight
        // `composerBottomConstraint` places a base line 4 pt above the keyboard
        // (or the safe area, or a drawer); the composer then sits `composerDrop`
        // below that line, which follows the keyboard's progress.
        view.addLayoutGuide(composerBase)
        let composerBottom = composerBase.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -4)
        composerBottomConstraint = composerBottom
        let drop = composerContainer.bottomAnchor.constraint(equalTo: composerBase.bottomAnchor, constant: ConversationKeyboardPinGeometry.restDrop)
        composerDropConstraint = drop
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: ConversationHeaderView.contentHeight),
            topEdgeFade.topAnchor.constraint(equalTo: view.topAnchor),
            topEdgeFade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topEdgeFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topEdgeFade.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: ConversationTopEdgeFade.extent),
            composerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBottom,
            drop,
            composerBase.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBase.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBase.heightAnchor.constraint(equalToConstant: 0),
            composer.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
            composerHeight,
        ])

        if #available(iOS 26.0, *) {
            // The top edge is ConversationTopEdgeFade (Messages washes, never blurs, there).
            // Over a conversation background ChatKit clears the pocket color
            // (`_updateStaticPocketColor`: nil when the transcript background
            // is active), so the system pocket under the header takes over;
            // the header is its container (see +Background).
            collectionView.topEdgeEffect.isHidden = true
            collectionView.topEdgeEffect.style = .soft
            let top = UIScrollEdgeElementContainerInteraction()
            top.scrollView = collectionView
            top.edge = .top
            header.addInteraction(top)
            collectionView.bottomEdgeEffect.style = .soft
            let bottom = UIScrollEdgeElementContainerInteraction()
            bottom.scrollView = collectionView
            bottom.edge = .bottom
            composerContainer.addInteraction(bottom)
        }

        installGestures()
        installTimestampDrawer()
        installMentions()
        installAudio()
        installEffects()
        installBackground()
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
        installCatchUp()
        observeKeyboardFrames()
        installTranslation()
        store.onChange = { [weak self] change in self?.storeDidChange(change) }
        store.start()
        rebuild(change: .reset)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        updateViewing()
        focusComposerIfEmpty()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isOnScreen = false
        store.endVisit()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        followKeyboardProgress()
        updateInsets()
        // A full field stops 3.3 pt below the header's bottom edge, just under
        // the name pill (Messages: field top 157.3 pt, pill bottom 148.6 pt).
        let fieldBottom = composerContainer.frame.maxY - 4
        composer.maximumFieldHeight = max(ConversationTheme.composerMinHeight, fieldBottom - header.frame.maxY - 3.3)
        layoutReplyOverlay()
        if store.background != nil, !Self.usesSystemTopPocket {
            collectionView.topFadeHeaderBottom = header.frame.maxY - collectionView.frame.minY
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            layoutCache.invalidateAll()
            invalidateRowMetrics()
            collectionView.reloadData()
        }
        if traitCollection.changesTextMetrics(from: previousTraitCollection) {
            // Dynamic Type or Bold Text: every row re-measures at the new size.
            layoutCache.invalidateAll()
            invalidateRowMetrics()
            layout.invalidateLayout()
            collectionView.reloadData()
            view.setNeedsLayout()
        }
    }

    // MARK: Insets

    /// Keeps the last message directly above the composer and the first below
    /// the header. When the bottom inset changes (keyboard, composer growth)
    /// the visible content moves with it, unless the finger is driving.
    func updateInsets() {
        let top = header.frame.maxY + 4
        // The last body rests 16.71 pt above the field (ChatKit's send
        // lands it there on iOS 26 and 27): the field sits 4 pt into the
        // container and the content ends 6 pt below the last row.
        let bottom = max(0, view.bounds.maxY - composerContainer.frame.minY) + 16.71 - 4 - 6 + translationIndicatorReserve
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
                // Inside the keyboard's animation, so the newest message
                // rides the keyboard with the composer, frame by frame.
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

    /// 0 with the keyboard hidden, 1 when it is fully shown (the share of the
    /// docked keyboard above the bottom safe area); an interactive dismissal
    /// passes through every value in between.
    var keyboardProgress: CGFloat {
        let rest = view.bounds.maxY - view.safeAreaInsets.bottom
        let top = view.keyboardLayoutGuide.layoutFrame.minY
        guard top < rest - 0.5 else { return 0 }
        let travel = dockedKeyboardHeight - view.safeAreaInsets.bottom
        guard travel > 1 else { return 1 }
        return min(1, (rest - top) / travel)
    }

    /// The finger's location while it drags the transcript over a shown
    /// keyboard (an interactive dismissal moves the keyboard with it).
    private var keyboardDragLocation: CGFloat? {
        guard collectionView.isTracking, keyboardEndTop < view.bounds.maxY - view.safeAreaInsets.bottom - 0.5 else { return nil }
        return collectionView.panGestureRecognizer.location(in: view).y
    }

    /// Applies the keyboard's position to the composer in the same layout
    /// pass (and so the same animation) that moves the keyboard guide; during
    /// an interactive dismissal, on every finger move.
    func followKeyboardProgress() {
        // A drawer in the keyboard's place keeps the composer on its base line.
        let p = photoDrawer == nil ? keyboardProgress : 0
        let restingGuideTop = view.bounds.maxY - view.safeAreaInsets.bottom
        let guideTop = view.keyboardLayoutGuide.layoutFrame.minY
        let keyboardTop = ConversationKeyboardPinGeometry.keyboardTop(
            guideTop: guideTop, restingGuideTop: restingGuideTop,
            screenBottom: view.bounds.maxY, dragLocation: keyboardDragLocation
        )
        let drop: CGFloat
        if photoDrawer != nil {
            drop = 0
        } else if let keyboardTop {
            drop = ConversationKeyboardPinGeometry.drop(keyboardTop: keyboardTop, guideTop: guideTop, restingGuideTop: restingGuideTop)
        } else {
            // The finger let go and UIKit already moved the guide: hold the
            // composer where it was until the keyboard's animation starts.
            drop = lastComposerBottom - (guideTop + (composerBottomConstraint?.constant ?? -4))
        }
        defer { lastComposerBottom = composerContainer.frame.maxY }
        guard composerDropConstraint?.constant != drop || composer.keyboardProgress != p else { return }
        composerDropConstraint?.constant = drop
        composer.keyboardProgress = p
        view.layoutIfNeeded()
    }

    private func observeKeyboardFrames() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignComposerIfKeyboardGone() }
        }
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated {
                guard let self else { return }
                if let end, end.height > 0 { self.dockedKeyboardHeight = end.height }
            }
        }
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated {
                guard let self, let end, let window = self.view.window else { return }
                let screen = window.screen.coordinateSpace
                let frame = self.view.convert(end, from: screen)
                self.keyboardEndTop = frame.height > 0 ? frame.minY : self.view.bounds.maxY
                // UIKit posts this inside the keyboard's animation. Ending an
                // interactive dismissal moves the guide there but lays out
                // later, outside it; laying out now lets the composer and
                // transcript ride the keyboard's remaining curve instead of
                // jumping (and leaves the composer at rest when the guide did
                // not move because the finger was already past the safe area).
                self.view.setNeedsLayout()
                self.layoutRidingKeyboardAnimation()
            }
        }
    }

    /// Keyboard hidden means the composer is not first responder (see
    /// `ConversationKeyboardFocusPolicy`), whichever path hid it, so a
    /// single tap on the field always brings the keyboard back.
    private func resignComposerIfKeyboardGone() {
        let restingGuideTop = view.bounds.maxY - view.safeAreaInsets.bottom
        let state = ConversationKeyboardFocusPolicy.KeyboardHidden(
            composerIsFirstResponder: composer.textView.isFirstResponder,
            keyboardGuideAtRest: view.keyboardLayoutGuide.layoutFrame.minY >= restingGuideTop - 0.5,
            hardwareKeyboardAttached: GCKeyboard.coalesced != nil,
            sceneIsForegroundActive: view.window?.windowScene?.activationState == .foregroundActive,
            isTransitioningSize: isTransitioningSize
        )
        guard ConversationKeyboardFocusPolicy.composerResigns(after: state) else { return }
        composer.textView.resignFirstResponder()
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        isTransitioningSize = true
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.isTransitioningSize = false }
    }

    /// Lays out inside the keyboard's animation, in an animation of our own.
    ///
    /// A nested animation inherits the keyboard's remaining duration and
    /// spring, so the composer and transcript still ride its curve. It keeps
    /// our views' animations out of UIKit's own block, though: when an
    /// interactive dismissal ends (a fling, or a release partway down),
    /// UIKit resigns the text view from that block's completion, and with
    /// the composer's animation joined to it that completion never ran. The
    /// keyboard left while the field stayed first responder, so tapping the
    /// field showed its edit menu instead of bringing the keyboard back.
    private func layoutRidingKeyboardAnimation() {
        let remaining = UIView.inheritedAnimationDuration
        guard remaining > 0 else {
            view.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: remaining, delay: 0, options: [.beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
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
        detailsOverlay?.storeDidChange(change)
        switch change {
        case .connection:
            header.setConnectionStatus(store.connection == .connected ? nil : String(localized: "conversation.header.connecting", defaultValue: "Connecting…", bundle: .module))
            if let info = store.info { header.configure(info: info, meID: store.meID, unreadCount: headerUnreadCount) }
            return
        case .readState:
            updateCatchUp()
            return
        case .background:
            applyBackground(animated: true)
            return
        case .draft:
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
        updateCatchUp()
        if let info = store.info, header.window != nil, !hasConfiguredHeader {
            hasConfiguredHeader = true
            configuredHeaderTitle = info.title
            header.configure(info: info, meID: store.meID, unreadCount: headerUnreadCount)
        } else if let info = store.info, hasConfiguredHeader, info.title != configuredHeaderTitle {
            // "… named the conversation": the header takes the new name.
            configuredHeaderTitle = info.title
            header.configure(info: info, meID: store.meID, unreadCount: headerUnreadCount)
        }
        maybeLoadOlder()
        focusComposerIfEmpty()
    }

    private var hasConfiguredHeader = false
    private var configuredHeaderTitle: String?
    private var didFocusEmptyConversation = false

    /// A conversation with no messages yet opens with the keyboard up, as a
    /// new message does in Messages.
    func focusComposerIfEmpty() {
        guard !didFocusEmptyConversation, store.hasLoadedNewest, store.older == .exhausted,
              store.messages.isEmpty, view.window != nil else { return }
        didFocusEmptyConversation = true
        composer.textView.becomeFirstResponder()
    }

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
        let oldIDs = rowIDs
        let newIDs = newRows.map(\.id)
        let oldIndex = rowIndex
        var newIndex: [String: Int] = [:]
        newIndex.reserveCapacity(newIDs.count)
        for (index, id) in newIDs.enumerated() { newIndex[id] = index }

        // Before anything is shown, or when the whole window changed, reload.
        if !hasPositionedInitially || change == .reset && oldIDs.isEmpty {
            rows = newRows
            rowIndex = newIndex
            rowIDs = newIDs
            invalidateRowMetrics()
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            if !newRows.isEmpty {
                // Also stops the bounce the empty transcript may still be
                // running, which would otherwise carry on from the new offset
                // and leave the newest message under the composer.
                collectionView.setContentOffset(bottomOffset, animated: false)
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
        // One row changing place (Try Again sends a failed message again, so
        // it moves to the bottom) moves in the batch instead of reloading all.
        let moved = Self.singleMove(from: commonOld, to: commonNew)
        let structural = commonOld == commonNew || moved != nil
        var updated: [IndexPath] = []
        if structural {
            for id in commonNew {
                guard let o = oldIndex[id], let n = newIndex[id], rows[o] != newRows[n] else { continue }
                updated.append(IndexPath(item: n, section: 0))
            }
        }

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
            case let .message(model) where !model.isOutgoing && animateLive && model.message.effect != nil:
                // A bubble effect is the row's entrance; screen effects keep the pop.
                if !queueArrivalEffect(model) { arrivingRowIDs.append(model.rowID) }
            case let .message(model) where !model.isOutgoing && animateLive: arrivingRowIDs.append(model.rowID)
            case .typing: arrivingRowIDs.append(id)
            case .loadingOlder, .notice, .systemEvent, .unavailability: appearances[id] = .fade
            default: break
            }
        }

        // A typing indicator replaced by the message it announced cross-fades
        // with it in place, as ChatKit's layout does (the indicator's final
        // attributes and the message's initial ones are alpha 0; only plugin
        // items skip the fade). In a group the typer's avatar flies from the
        // indicator to the message instead of fading (see `flyTypingAvatar`).
        if animateLive, inserted.contains(where: { if case .message = newRows[$0.item] { return true } else { return false } }) {
            for indexPath in deleted where indexPath.item < rows.count {
                guard case .typing = rows[indexPath.item],
                      let cell = collectionView.cellForItem(at: indexPath) as? TypingCell else { continue }
                if let handoff = inserted.last(where: { indexPath in
                    if case let .message(model) = newRows[indexPath.item] { return !model.isOutgoing } else { return false }
                }) {
                    typingHandoffRowID = newIDs[handoff.item]
                    if !cell.avatar.isHidden {
                        typingAvatarHandoff = (cell.avatar.convert(cell.avatar.bounds, to: collectionView), cell.avatar.initials)
                        UIView.performWithoutAnimation { cell.avatar.isHidden = true }
                    }
                }
            }
        }
        // Non-animated changes (a page landing) can regroup visible rows
        // (spacing, tail, sender name); rows that move a few points glide.
        let screenBefore = animateLive ? [:] : visibleScreenTops()

        // Undo Send: the bubble dissolves where it stood while its notice fades in.
        if animateLive {
            for indexPath in deleted where indexPath.item < rows.count {
                guard case let .message(model) = rows[indexPath.item], newIndex["unsent:\(model.rowID)"] != nil,
                      let cell = collectionView.cellForItem(at: indexPath) as? MessageCell else { continue }
                dissolve(cell)
            }
        }

        layoutCache.forget(rowIDs: deleted.lazy.map { oldIDs[$0.item] })
        let carriedMetrics = structural ? carriedRowMetrics(newIDs: newIDs, oldIndex: oldIndex, updated: updated) : nil
        let updates = {
            self.rows = newRows
            self.rowIndex = newIndex
            self.rowIDs = newIDs
            if let carriedMetrics { self.rowMetrics = carriedMetrics } else { self.invalidateRowMetrics() }
            if structural {
                self.collectionView.deleteItems(at: deleted)
                self.collectionView.insertItems(at: inserted)
                if let moved, let from = oldIndex[moved], let to = newIndex[moved] {
                    self.collectionView.moveItem(at: IndexPath(item: from, section: 0), to: IndexPath(item: to, section: 0))
                }
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
            // A flight still in the air rides with its row (a rapid second send).
            let flightTops = flightScreenTops()
            // Pinned: insertions and the scroll to the new bottom share one
            // spring, ChatKit's transcript update spring on iOS 26 and 27
            // (stiffness 438.649, damping 41.888: 0.3 s, critically damped).
            UIView.animate(springDuration: 0.3, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.collectionView.performBatchUpdates(updates)
                if structural, !updated.isEmpty { self.collectionView.reconfigureItems(at: updated) }
                self.collectionView.layoutIfNeeded()
                self.collectionView.contentOffset = self.bottomOffset
                self.moveFlights(from: flightTops)
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
            if isScrollingToTop {
                // Stop a running scroll-to-top so it cannot carry the reader
                // past the anchor into the page that just landed.
                collectionView.setContentOffset(collectionView.contentOffset, animated: false)
                isScrollingToTop = false
            }
            UIView.performWithoutAnimation {
                self.collectionView.performBatchUpdates(updates)
                if structural, !updated.isEmpty { self.collectionView.reconfigureItems(at: updated) }
                self.collectionView.layoutIfNeeded()
                self.restore(anchor)
            }
            glideRegrouped(from: screenBefore)
        }
        appearances = appearances.filter { flyingRowIDs.contains($0.key) }
        popArrivals()
        announceArrivals(newRows, inserted: inserted, isLive: animateLive)
        playQueuedEffects()
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

    /// New incoming bubbles appear at their final place in the transcript and
    /// fade in while the transcript scrolls them up from under the composer,
    /// as ChatKit's transcript layout does (its appearing attributes are the
    /// final frame at alpha 0; balloon cells add no insertion transform). The
    /// message replacing a typing indicator shows at full opacity at once.
    /// A typing indicator runs its own staged grow.
    private func popArrivals() {
        let ids = arrivingRowIDs
        arrivingRowIDs = []
        let handoff = typingHandoffRowID
        typingHandoffRowID = nil
        let avatarHandoff = typingAvatarHandoff
        typingAvatarHandoff = nil
        for id in ids {
            guard let indexPath = indexPath(for: id), let cell = collectionView.cellForItem(at: indexPath) else { continue }
            if let cell = cell as? TypingCell {
                UIView.performWithoutAnimation { cell.contentView.alpha = 1 }
                cell.indicator.grow()
                continue
            }
            UIView.performWithoutAnimation { cell.contentView.alpha = 0 }
            UIView.animate(withDuration: Self.arrivalFadeDuration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                cell.contentView.alpha = 1
            }
            if id == handoff, let avatarHandoff, let cell = cell as? MessageCell {
                flyTypingAvatar(from: avatarHandoff.frame, initials: avatarHandoff.initials, to: cell)
            }
        }
    }

    /// ChatKit's `CKGroupTypingAvatarAnimationCoordinator` (iOS 26.5 and
    /// 27.0): a copy of the typer's avatar springs from the indicator's
    /// avatar to the message's (mass 2, stiffness 370, damping 40) while the
    /// message's own avatar stays hidden, so the sender never doubles or fades.
    private func flyTypingAvatar(from start: CGRect, initials: String, to cell: MessageCell) {
        guard !cell.avatar.isHidden, let indexPath = collectionView.indexPath(for: cell),
              let rowFrame = layout.frame(at: indexPath.item) else { return }
        // The cell's final place: it may still be moving with the batch.
        let end = cell.avatar.frame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        let overlay = ConversationAvatarView(frame: start)
        overlay.configure(initials: initials, colorHex: nil)
        overlay.isUserInteractionEnabled = false
        collectionView.addSubview(overlay)
        let target = cell.avatar
        UIView.performWithoutAnimation { target.alpha = 0 }
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: UISpringTimingParameters(mass: 2, stiffness: 370, damping: 40, initialVelocity: .zero))
        animator.addAnimations {
            overlay.frame = end
        }
        animator.addCompletion { _ in
            target.alpha = 1
            overlay.removeFromSuperview()
        }
        animator.startAnimation()
    }

    /// `CKUIBehavior.scrollInNewMessageAnimationDuration`.
    static let arrivalFadeDuration: TimeInterval = 0.3

    /// Unsent bubble: Messages' pop (it swells, then breaks into debris)
    /// over a snapshot; the cell itself is hidden so the row's own removal
    /// shows nothing. Reduce Motion fades it instead.
    private func dissolve(_ cell: MessageCell) {
        let frame = cell.liftedContentFrame
        guard frame.width > 0, frame.height > 0 else { return }
        let format = UIGraphicsImageRendererFormat.preferred()
        let image = UIGraphicsImageRenderer(bounds: frame, format: format).image { _ in
            cell.shiftable.drawHierarchy(in: cell.shiftable.bounds, afterScreenUpdates: false)
        }
        guard let cgImage = image.cgImage else { return }
        let host = UIView(frame: view.bounds)
        host.isUserInteractionEnabled = false
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(host, aboveSubview: collectionView)
        UIView.performWithoutAnimation { cell.contentView.alpha = 0 }
        ConversationPopEffect.play(
            image: cgImage,
            frame: cell.shiftable.convert(frame, to: host),
            in: host.layer,
            contentsScale: format.scale,
            yUp: false,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        ) {
            host.removeFromSuperview()
        }
    }

    /// The id whose removal makes both orders equal, when exactly one row moved.
    static func singleMove(from old: [String], to new: [String]) -> String? {
        guard old.count == new.count, old != new else { return nil }
        guard let first = old.indices.first(where: { old[$0] != new[$0] }) else { return nil }
        for candidate in [old[first], new[first]] {
            if old.filter({ $0 != candidate }) == new.filter({ $0 != candidate }) { return candidate }
        }
        return nil
    }

    private func sentByMeChange(_ change: ConversationStoreChange) -> Bool {
        if case let .live(inserted, mine) = change { return mine && !inserted.isEmpty }
        return false
    }

    /// Loads the page above when `offsetY` (the current offset, or where a
    /// fling will come to rest) is near the top-of-history spinner. Messages
    /// checks the fling target at release too, so a hard fling toward the top
    /// starts its fetch before the deceleration gets there.
    func maybeLoadOlder(targetOffsetY: CGFloat? = nil) {
        guard hasPositionedInitially, store.hasLoadedNewest, !isScrollingToTop else { return }
        let fromTop = (targetOffsetY ?? collectionView.contentOffset.y) + collectionView.adjustedContentInset.top
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
        if closeInfo() { return }
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
        guard store.info != nil, detailsOverlay == nil else { return }
        view.endEditing(true)
        guard let overlay = ConversationDetailsOverlay(store: store) else { return }
        configureBackgroundRow(overlay)
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(overlay, belowSubview: header)
        detailsOverlay = overlay
        header.setDetailsShown(true, animated: true)
        overlay.present(from: header.convert(header.detailsSourceFrame, to: view))
    }

    /// Closes the details panel; returns false when none is open.
    @discardableResult
    func closeInfo() -> Bool {
        guard let overlay = detailsOverlay else { return false }
        detailsOverlay = nil
        header.setDetailsShown(false, animated: true)
        overlay.dismiss(to: header.convert(header.detailsSourceFrame, to: view)) {}
        UIAccessibility.post(notification: .screenChanged, argument: header)
        return true
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
            cell.audioDelegate = self
            cell.configure(model: model, layout: cellLayout, text: layoutCache.attributedText(for: model))
            cell.setFlightHidden(flyingRowIDs.contains(model.rowID))
            cell.timestampRevealDistance = timestampRevealDistance
            cell.timestampReveal = timestampReveal
            cell.setSelectionMode(isSelecting, selected: selectedRowIDs.contains(model.rowID), animated: false)
            applyReplyBacking(to: cell, model: model)
            cell.accessibilityIdentifier = "conversation.message.\(model.message.id)"
            configureAccessibility(cell, model: model)
            return cell
        case let .timestamp(_, date):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TimestampCell.reuseID, for: indexPath) as! TimestampCell
            cell.configure(date: date)
            return cell
        case let .notice(notice):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TimestampCell.reuseID, for: indexPath) as! TimestampCell
            cell.configure(notice: notice)
            return cell
        case let .sendLaterHeader(rowID, date, failed):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SendLaterHeaderCell.reuseID, for: indexPath) as! SendLaterHeaderCell
            cell.configure(date: date, failed: failed, menu: sendLaterMenu(for: rowID))
            return cell
        case let .systemEvent(_, text):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SystemEventCell.reuseID, for: indexPath) as! SystemEventCell
            cell.configure(text)
            return cell
        case let .unavailability(name, messageID):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: UnavailabilityCell.reuseID, for: indexPath) as! UnavailabilityCell
            cell.configure(name: name, showsNotifyAnyway: messageID != nil)
            cell.onNotifyAnyway = { [weak self] in
                guard let messageID else { return }
                self?.store.notifyAnyway(messageID: messageID)
            }
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
        // Messages ignores a status-bar tap while a message's menu covers the
        // transcript (CKChatController isFullScreenBalloonViewOnScreen).
        if view.subviews.contains(where: { $0 is MessageActionOverlay }) { return false }
        // A status-bar tap leaves the bottom on purpose.
        isPinnedToBottom = false
        isScrollingToTop = true
        return true
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        isScrollingToTop = false
        maybeLoadOlder()
    }

    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if velocity.y < 0 { maybeLoadOlder(targetOffsetY: targetContentOffset.pointee.y) }
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A flight is pinned to the screen; once the reader scrolls, show the real row.
        landAllFlights()
        dismissPhotoDrawer()
        isScrollingToTop = false
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            isPinnedToBottom = isNearBottom(tolerance: 44)
            trimHistoryIfResting()
        }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isPinnedToBottom = isNearBottom(tolerance: 44)
        trimHistoryIfResting()
    }

    /// A reader who scrolled back down and rests on the newest message bounds
    /// the loaded window, so later updates stay cheap (rows far above reload
    /// as pages if the reader returns to them).
    func trimHistoryIfResting() {
        guard isPinnedToBottom, !collectionView.isTracking, !collectionView.isDecelerating,
              activeFlights.isEmpty, pendingFlight == nil, replyTarget == nil, editingMessageID == nil,
              !isSelecting, replyOverlay == nil else { return }
        store.trimOlderIfLarge(preserving: selectedRowIDs)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // The finger drags the keyboard below the safe area, where the guide
        // stops reporting it; the composer follows the finger there.
        if keyboardDragLocation != nil { followKeyboardProgress() }
        if scrollView.isTracking || scrollView.isDecelerating {
            isPinnedToBottom = isNearBottom(tolerance: 44)
        }
        // The scroll-to-top is over once it rests at the top (not every path
        // reports scrollViewDidScrollToTop).
        if isScrollingToTop, scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5 {
            isScrollingToTop = false
        }
        maybeLoadOlder()
        for case let cell as MessageCell in collectionView.visibleCells { cell.updateScreenGradients() }
        // Reading follows viewing (see +CatchUp), not scroll position:
        // Messages reads the whole conversation on open.
        updateCatchUp()
    }

    public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? TypingCell)?.indicator.startAnimating()
    }

    func transcriptItemCount() -> Int { rows.count }

    func transcriptWillPrepare(width: CGFloat) {
        let margin = layoutMargin
        if rowMetricsKey.width != width || rowMetricsKey.margin != margin {
            rowMetricsKey = (width, margin)
            invalidateRowMetrics()
        } else if rowMetrics.count != rows.count {
            invalidateRowMetrics()
        }
    }

    func transcriptHeight(at index: Int, width: CGFloat) -> CGFloat {
        if index < rowMetrics.count, !rowMetrics[index].height.isNaN { return rowMetrics[index].height }
        let height = measuredHeight(at: index, width: width)
        if index < rowMetrics.count { rowMetrics[index].height = height }
        return height
    }

    func transcriptBottomOverhang() -> CGFloat {
        guard case let .message(model) = rows.last else { return 0 }
        return layoutCache.layout(for: model, width: collectionView.bounds.width, margin: layoutMargin).tailOverhang
    }

    private func measuredHeight(at index: Int, width: CGFloat) -> CGFloat {
        switch rows[index] {
        case let .message(model):
            return layoutCache.layout(for: model, width: width, margin: layoutMargin).height
        case .timestamp, .notice: return TimestampCell.height
        case .sendLaterHeader: return SendLaterHeaderCell.height
        case let .systemEvent(_, text): return SystemEventCell.height(text, width: width)
        case let .unavailability(_, messageID): return UnavailabilityCell.height(showsNotifyAnyway: messageID != nil)
        case .loadingOlder: return LoadingCell.height
        case .conversationStart: return ConversationStartCell.height
        case .typing: return TypingCell.height(isGroup: store.info?.kind == .group)
        }
    }

    func transcriptSpacing(before index: Int) -> CGFloat {
        if index < rowMetrics.count, !rowMetrics[index].spacing.isNaN { return rowMetrics[index].spacing }
        let spacing = measuredSpacing(before: index)
        if index < rowMetrics.count { rowMetrics[index].spacing = spacing }
        return spacing
    }

    private func measuredSpacing(before index: Int) -> CGFloat {
        guard case let .message(model) = rows[index] else {
            if case .typing = rows[index], index > 0, case let .message(previous) = rows[index - 1],
               let typer = store.typingParticipantIDs.first, previous.message.senderID == typer {
                return ConversationTheme.groupedSpacing
            }
            return index > 0 && isMessage(index - 1) ? 10 : 0
        }
        guard index > 0, case let .message(previous) = rows[index - 1] else { return 4 }
        // Gaps run body to body; the previous row's tail hangs into this one.
        let overhang = layoutCache.layout(for: previous, width: collectionView.bounds.width, margin: layoutMargin).tailOverhang
        let gap = model.isFirstInGroup ? ConversationTheme.ungroupedSpacing : ConversationTheme.groupedSpacing
        return max(0, gap - overhang)
    }

    struct RowMetrics {
        var height: CGFloat = .nan
        var spacing: CGFloat = .nan
    }

    /// Forgets every measurement (width, margin or appearance changed).
    func invalidateRowMetrics() {
        rowMetrics = Array(repeating: RowMetrics(), count: rows.count)
    }

    /// Metrics for the new rows. A row keeps its height when it is unchanged,
    /// and its spacing when, in addition, the row above it is the same
    /// unchanged row (spacing depends only on the pair).
    private func carriedRowMetrics(newIDs: [String], oldIndex: [String: Int], updated: [IndexPath]) -> [RowMetrics] {
        var metrics = [RowMetrics](repeating: RowMetrics(), count: newIDs.count)
        guard rowMetrics.count == rows.count else { return metrics }
        var changed = [Bool](repeating: false, count: newIDs.count)
        for indexPath in updated { changed[indexPath.item] = true }
        var previousOld: Int?
        for (index, id) in newIDs.enumerated() {
            let old = oldIndex[id]
            defer { previousOld = changed[index] ? nil : old }
            guard let old, !changed[index] else { continue }
            metrics[index].height = rowMetrics[old].height
            let samePredecessor = index == 0 ? old == 0 : previousOld.map { $0 == old - 1 } ?? false
            if samePredecessor { metrics[index].spacing = rowMetrics[old].spacing }
        }
        return metrics
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

    /// Over a conversation background, the header's bottom edge (in this
    /// view's frame coordinates): the transcript fades out above it with
    /// `ConversationTopEdgeFade`'s ramp, so the background, not a color
    /// wash, shows under the header. Nil removes the mask.
    var topFadeHeaderBottom: CGFloat? {
        didSet {
            guard topFadeHeaderBottom != oldValue else { return }
            if topFadeHeaderBottom == nil {
                layer.mask = nil
            } else if layer.mask !== topFadeMask {
                layer.mask = topFadeMask
            }
            lastMaskGeometry = nil
            setNeedsLayout()
        }
    }

    let topFadeMask = CAGradientLayer()
    private var lastMaskGeometry: (CGFloat, CGFloat)?

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTopFadeMask()
    }

    /// The mask lives in the scroll view's bounds space, so it follows the
    /// content offset to stay fixed on screen.
    private func updateTopFadeMask() {
        guard let headerBottom = topFadeHeaderBottom else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topFadeMask.frame = bounds
        let geometry = (bounds.height, headerBottom)
        if lastMaskGeometry.map({ $0 != geometry }) ?? true {
            lastMaskGeometry = geometry
            let ramp = ConversationTopEdgeFade.ramp(height: bounds.height, headerBottom: headerBottom)
            topFadeMask.colors = ramp.map { UIColor.black.withAlphaComponent(1 - $0.wash).cgColor }
            topFadeMask.locations = ramp.map { NSNumber(value: Double($0.location)) }
        }
        CATransaction.commit()
    }

    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.bottom = max(insets.bottom, edgeBottomInset)
        return insets
    }

    /// As in Messages (`CKTranscriptCollectionViewController loadView`), the
    /// scroll pan may move sideways so a left drag reaches the send-time
    /// drawer with the scroll view's own slop and no directional lock; the
    /// content itself never scrolls sideways (the drawer draws the offset).
    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        alwaysBounceHorizontal = true
        showsHorizontalScrollIndicator = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = CGPoint(x: 0, y: newValue.y) }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(CGPoint(x: 0, y: contentOffset.y), animated: animated)
    }
}

#endif
