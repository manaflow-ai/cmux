import AppKit
import CmuxHomeCore
import MessagesLabSidebar
import Observation

/// Home's Messages-style page (cmux-next `HomeSidebarSplitView`): the Chief
/// conversation list on the left and the selected conversation's
/// ``ChiefTranscriptView`` on the right, with a real divider. The list sits
/// between its minimum and half the window, starts at its preferred 320 pt,
/// keeps the user's width, and a double-click on the divider resets it.
@MainActor
final class ChiefHomeView: NSView, NSSplitViewDelegate {
    private static let widthKey = "chief.home.sidebarWidth"
    private static let selectionKey = "chief.home.selectedConversation"
    private static let unreadMarksKey = "chief.home.unreadMarks"
    /// Half the grab area on each side of the 1 pt divider.
    private static let grab: CGFloat = 4

    private let split = ChiefHomeSplitView()
    private let sidebar = ChiefConversationListView()
    private let content = NSView()
    private(set) var transcript: ChiefTranscriptView?
    private(set) var selected: ConversationID
    private var placed = false
    private var stopped = false
    private var observers: [any NSObjectProtocol] = []
    /// Conversations the user marked unread (the owner's read cursor only moves forward).
    private var unreadMarks: Set<String>
    private let defaults: UserDefaults
    private var theme = ChiefTheme.current()
    /// The Chief's avatar text (``ChiefProfile``), nil for initials.
    private var avatarText: String?

    /// Whether the host shows Home now; a hidden Home sends no read receipts.
    var isActive = true { didSet { transcript?.isActive = isActive } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let service = ChiefService.shared
        service.start()
        selected = defaults.string(forKey: Self.selectionKey).map { ConversationID($0) } ?? service.defaultConversationID
        unreadMarks = Set(defaults.stringArray(forKey: Self.unreadMarksKey) ?? [])
        super.init(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.onDoubleClickDivider = { [weak self] in self?.resetWidth() }
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(content)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.frame = bounds
        split.autoresizingMask = [.width, .height]
        addSubview(split)
        connectList()
        observeTheme()
        applyTheme()
        avatarText = service.home.flatMap { ChiefProfile.load(from: $0).avatar }
        show(selected)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // Not an isolated deinit (Swift 6.0 has none): the main-thread check guards the hop.
    deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            stop()
        }
    }

    /// Closes the shown conversation. Once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        transcript?.stop()
    }

    /// Puts the keyboard in the selected conversation's message box.
    func focusComposer() {
        transcript?.focusComposer()
    }

    /// Shows `conversation` (from the list, a link, or a new conversation).
    func select(_ conversation: ConversationID) {
        guard conversation != selected || transcript == nil else { return }
        selected = conversation
        defaults.set(conversation.rawValue, forKey: Self.selectionKey)
        show(conversation)
        reload()
    }

    private func show(_ conversation: ConversationID) {
        if unreadMarks.remove(conversation.rawValue) != nil { saveUnreadMarks() }
        let hadFocus = transcript.map { view in
            (window?.firstResponder as? NSView).map { $0.isDescendant(of: view) } ?? false
        } ?? false
        transcript?.stop()
        transcript?.removeFromSuperview()
        let view = ChiefTranscriptView(conversation: conversation)
        view.isActive = isActive
        view.onOpenConversation = { [weak self] id in self?.select(id) }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        transcript = view
        if hadFocus { view.focusComposer() }
    }

    // MARK: List

    private func connectList() {
        let list = sidebar.list
        list.onSelect = { [weak self] id in
            guard let id else { return }
            self?.select(ConversationID(id))
        }
        list.onSetPinned = { [weak self] on, id in self?.setPinned(on, ConversationID(id)) }
        list.onPlacePinned = { [weak self] id, index in self?.place(ConversationID(id), at: index) }
        list.onSetRead = { [weak self] read, id in self?.setRead(read, ConversationID(id)) }
        list.menuItems = { [weak self] _ in
            [CmuxSidebarMenuItem(title: ChiefStrings.newConversation) { self?.newConversation() }]
        }
        sidebar.onNewConversation = { [weak self] in self?.newConversation() }
    }

    /// Shows the store's conversations after every change (Observation, no polling).
    private func reload() {
        guard !stopped, let store = ChiefService.shared.storeIfStarted else { return }
        withObservationTracking {
            showEntries(store.rows)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    private func showEntries(_ rows: [InboxRow], pinnedOrder: [ConversationID]? = nil) {
        let me = ChiefService.shared.me
        let avatar = avatarText.map(Self.listAvatar)
        let pinned = pinnedOrder ?? rows.filter { $0.summary.pinRank != nil }
            .sorted { ($0.summary.pinRank ?? 0, $0.id.rawValue) < ($1.summary.pinRank ?? 0, $1.id.rawValue) }
            .map(\.id)
        let pinnedSet = Set(pinned)
        let entries = rows.map { row -> CmuxSidebarEntry in
            let others = row.summary.participants.filter { $0.id != me }
            let marked = unreadMarks.contains(row.id.rawValue)
            return CmuxSidebarEntry(
                id: row.id.rawValue,
                title: row.title.isEmpty ? (others.first?.displayName ?? ChiefStrings.chiefName) : row.title,
                people: others.map { CmuxSidebarEntry.Person(id: $0.id.rawValue, name: $0.displayName, initials: $0.initials) },
                preview: row.preview, previewSender: nil, lastAt: row.timestamp,
                unreadCount: max(row.unread, marked ? 1 : 0), pinned: pinnedSet.contains(row.id), typing: row.isTyping,
                avatar: avatar)
        }
        // Pinned in their order first, then the rest newest first (the store's order).
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = pinned.compactMap { byID[$0.rawValue] } + entries.filter { !pinnedSet.contains(ConversationID($0.id)) }
        sidebar.list.show(ordered, pinned: pinned.map(\.rawValue))
        if sidebar.list.selectedID != selected.rawValue {
            if byID[selected.rawValue] != nil {
                sidebar.list.select(selected.rawValue)
            } else if !rows.isEmpty, ChiefService.shared.storeIfStarted?.isInboxCurrent == true {
                // The remembered conversation is gone: the default Chief's (after this pass).
                Task { @MainActor [weak self] in self?.select(ChiefService.shared.defaultConversationID) }
            }
        }
    }

    /// The Chief's avatar as the list draws it: a monogram (one or two
    /// letters) or one emoji on the grey disc.
    static func listAvatar(_ text: String) -> CmuxSidebarEntry.Avatar {
        ChiefProfile.isMonogram(text) ? .monogram(String(text.prefix(2))) : .emoji(String(text.prefix(1)))
    }

    private func setPinned(_ on: Bool, _ id: ConversationID) {
        guard let store = ChiefService.shared.storeIfStarted else { return }
        let rank = on ? (store.rows.compactMap(\.summary.pinRank).max() ?? -1) + 1 : nil
        perform(.setPinned(conversation: id, rank: rank))
    }

    /// A drag put `id` at `index` of the pinned grid: the new order shows at
    /// once, then every pinned conversation takes its new rank.
    private func place(_ id: ConversationID, at index: Int) {
        guard let store = ChiefService.shared.storeIfStarted else { return }
        var order = store.rows.filter { $0.summary.pinRank != nil && $0.id != id }
            .sorted { ($0.summary.pinRank ?? 0) < ($1.summary.pinRank ?? 0) }.map(\.id)
        order.insert(id, at: min(max(0, index), order.count))
        showEntries(store.rows, pinnedOrder: order)
        for (rank, conversation) in order.enumerated()
        where store.rows.first(where: { $0.id == conversation })?.summary.pinRank != rank {
            perform(.setPinned(conversation: conversation, rank: rank))
        }
    }

    private func setRead(_ read: Bool, _ id: ConversationID) {
        if read {
            if unreadMarks.remove(id.rawValue) != nil { saveUnreadMarks() }
            if let summary = ChiefService.shared.storeIfStarted?.summary(id), summary.lastSeq > 0 {
                perform(.setReadCursor(conversation: id, seq: summary.lastSeq))
            }
        } else {
            unreadMarks.insert(id.rawValue)
            saveUnreadMarks()
        }
        if let store = ChiefService.shared.storeIfStarted { showEntries(store.rows) }
    }

    private func saveUnreadMarks() {
        defaults.set(unreadMarks.sorted(), forKey: Self.unreadMarksKey)
    }

    private func perform(_ op: HomeOp) {
        guard let store = ChiefService.shared.storeIfStarted else { return }
        // task-owner: one op; ends with its reply (a refusal leaves the list as the owner has it)
        Task { _ = try? await store.perform(op) }
    }

    private func newConversation() {
        // task-owner: one op; ends with its reply
        Task { [weak self] in
            do {
                let id = try await ChiefService.shared.createConversation()
                self?.select(id)
                self?.focusComposer()
            } catch {
                self?.transcript?.showNotice(ChiefStrings.newConversationFailed)
            }
        }
    }

    // MARK: Theme

    private func observeTheme() {
        let center = NotificationCenter.default
        for name in [Notification.Name.ghosttyConfigDidReload, .ghosttyDefaultBackgroundDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTheme() } // main-proof: observer on queue: .main
            })
        }
        observers.append(center.addObserver(forName: ChiefProfile.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self else { return }
                self.avatarText = ChiefService.shared.home.flatMap { ChiefProfile.load(from: $0).avatar }
                if let store = ChiefService.shared.storeIfStarted { self.showEntries(store.rows) }
            }
        })
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        theme = ChiefTheme.current()
        sidebar.apply(theme)
    }

    // MARK: Width

    private func clamp(_ width: CGFloat) -> CGFloat {
        max(sidebar.minimumWidth, min(width, bounds.width / 2))
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let current = sidebar.frame.width
        if !placed {
            placed = true
            let saved = defaults.double(forKey: Self.widthKey)
            split.setPosition(clamp(saved > 0 ? CGFloat(saved) : sidebar.preferredWidth), ofDividerAt: 0)
        } else if current > clamp(current) {
            // The window shrank: the list stays within half of it (the saved width is kept).
            split.setPosition(clamp(current), ofDividerAt: 0)
        }
    }

    private func resetWidth() {
        defaults.removeObject(forKey: Self.widthKey)
        split.setPosition(clamp(sidebar.preferredWidth), ofDividerAt: 0)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        sidebar.minimumWidth
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        clamp(.greatestFiniteMagnitude)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // A window resize goes to the transcript; the list keeps its width.
        view !== sidebar
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: -Self.grab, dy: 0)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only the user's drag is kept (AppKit names the divider it moved).
        guard placed, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        defaults.set(Double(sidebar.frame.width), forKey: Self.widthKey)
    }
}

/// The page's split view: a double-click on the divider resets the list's width.
final class ChiefHomeSplitView: NSSplitView {
    var onDoubleClickDivider: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let first = arrangedSubviews.first,
           NSRect(x: first.frame.maxX, y: 0, width: dividerThickness, height: bounds.height).insetBy(dx: -4, dy: 0).contains(point) {
            onDoubleClickDivider()
            return
        }
        super.mouseDown(with: event)
    }
}
