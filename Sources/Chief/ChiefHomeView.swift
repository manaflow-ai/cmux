import AppKit
import CmuxFoundation
import CmuxHomeCore
import MessagesLabHome
import MessagesLabSidebar
import Observation

/// The conversation list and selected transcript inside a Chief pane.
///
/// The Home pane keeps one instance while its workspace is mounted: the list
/// and transcript are two views of the same selection, and leaving Home keeps
/// the draft and scroll position for that mounted pane.
@MainActor
final class ChiefHomeView: NSView {
    private static let selectionKey = "chief.home.selectedConversation"
    private static let unreadMarksKey = "chief.home.unreadMarks"
    private static let hiddenConversationsKey = "chief.home.hiddenConversations"
    private static let showsConversationsKey = "chief.home.showsConversations"

    /// The conversation list shown beside the transcript in the Home pane.
    let list = ChiefConversationListView()
    private(set) var transcript: ChiefTranscriptView?
    private(set) var selected: ConversationID
    private(set) var showsConversations: Bool
    private let remembersSelection: Bool
    private let divider = NSView()
    private var stopped = false
    // SAFETY: written only on the main actor; `deinit` reads it once no other
    // reference exists, and NotificationCenter removal is thread-safe.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    /// Conversations the user marked unread (the owner's read cursor only moves forward).
    private var unreadMarks: Set<String>
    /// Conversations hidden from this device's Home list. Home's source has no
    /// delete/archive operation yet, so this local projection is durable and
    /// reversible by starting a new conversation without mutating the owner.
    private var hiddenConversations: Set<String>
    private let defaults: UserDefaults
    /// The Chief's avatar as the list draws it (``ChiefAvatarArtwork``).
    private var listAvatar: CmuxSidebarEntry.Avatar?
    /// Home was activated before this view joined its window (first entry):
    /// the composer takes focus once it does.
    private var focusOnWindow = false
    /// Width reserved for the iMessage-style conversation list in the pane.
    private static let listWidth: CGFloat = 320

    /// Records a choice in the panel model for session restore and pane drags.
    var onSelectConversation: ((ConversationID) -> Void)?
    /// Snapshot for compact list hosts that still use the same projection.
    var onRowsChanged: (([CmuxSidebarEntry]) -> Void)?

    /// Whether the host shows Home now; a hidden Home sends no read receipts.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            transcript?.isActive = isActive
            if isActive { markSelectedReadIfShown() }
        }
    }

    init(defaults: UserDefaults = .standard, conversation: ConversationID? = nil,
         remembersSelection: Bool = true) {
        self.defaults = defaults
        self.remembersSelection = remembersSelection
        let service = ChiefService.shared
        service.start()
        let remembered = remembersSelection ? defaults.string(forKey: Self.selectionKey).map { ConversationID($0) } : nil
        selected = conversation ?? remembered ?? service.defaultConversationID
        showsConversations = remembersSelection
            ? (defaults.object(forKey: Self.showsConversationsKey) as? Bool ?? true)
            : false
        unreadMarks = Set(defaults.stringArray(forKey: Self.unreadMarksKey) ?? [])
        hiddenConversations = Set(defaults.stringArray(forKey: Self.hiddenConversationsKey) ?? [])
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(list)
        divider.wantsLayer = true
        divider.setAccessibilityElement(false)
        addSubview(divider)
        connectList()
        observeNotifications()
        listAvatar = ChiefAvatarArtwork.listAvatar(ChiefAvatarArtwork.current())
        applyCurrentAppearance()
        show(selected)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // Not an isolated deinit (Swift 6.0 has none). The host tears Home down
    // (``teardown()``); a view freed without it still stops its transcript: at
    // once on the main thread, else in one hop that carries the transcript
    // (never `self`) to the main actor.
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        guard !stopped, let transcript else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { transcript.stop() } // main-proof: this branch runs only on the main thread
        } else {
            // task-owner: one hop to the main actor; ends at once
            Task { @MainActor in transcript.stop() }
        }
    }

    /// Stops observing and closes the shown conversation (Chief turned off,
    /// or the host unmounted Home). Once until ``resumeIfTornDown()``.
    func teardown() {
        guard !stopped else { return }
        stopped = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        transcript?.stop()
    }

    /// Shows the selected conversation again after ``teardown()``, for a host
    /// that mounts the same Home again. Nothing when Home is running.
    func resumeIfTornDown() {
        guard stopped else { return }
        stopped = false
        observeNotifications()
        show(selected)
        reload()
    }

    /// Puts the keyboard in the selected conversation's message box.
    func focusComposer() {
        transcript?.focusComposer()
    }

    /// Shows `conversation` (from the list, a link, or a new conversation).
    func select(_ conversation: ConversationID, notifySelection: Bool = true) {
        guard conversation != selected || transcript == nil else { return }
        selected = conversation
        if remembersSelection { defaults.set(conversation.rawValue, forKey: Self.selectionKey) }
        show(conversation)
        reload()
        if notifySelection { onSelectConversation?(conversation) }
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
        view.onToggleConversations = { [weak self] in self?.toggleConversations() }
        view.showsConversations = showsConversations
        addSubview(view)
        transcript = view
        // Set both columns before the replacement transcript can be displayed.
        layoutColumns()
        // Opening a conversation is a read action even before AppKit has made
        // the window key. This keeps the list's dot from lagging behind the
        // conversation the user just chose (and avoids a capture-time race).
        markSelectedReadIfShown()
        if hadFocus { view.focusComposer() }
    }

    /// Applies the current window appearance to the embedded Messages list.
    func applyCurrentAppearance() {
        let theme = ChiefTheme.current()
        appearance = theme.appearance
        layer?.backgroundColor = theme.opaqueBackground.cgColor
        list.wantsLayer = true
        list.layer?.backgroundColor = theme.panelFill.cgColor
        divider.layer?.backgroundColor = theme.hairline.cgColor
        list.apply(
            isDark: theme.isDark,
            accent: (AppDelegate.shared?.accentColor ?? CmuxAccentColor()).nsColor(for: appearance)
        )
    }

    override var isFlipped: Bool { true }

    /// The list is local to this pane; hiding it gives the transcript the space.
    func toggleConversations() {
        showsConversations.toggle()
        if remembersSelection { defaults.set(showsConversations, forKey: Self.showsConversationsKey) }
        if !showsConversations,
           let responder = window?.firstResponder as? NSView, responder.isDescendant(of: list) {
            focusComposer()
        }
        transcript?.showsConversations = showsConversations
        layoutColumns()
    }

    override func layout() {
        super.layout()
        layoutColumns()
    }

    private func layoutColumns() {
        // In a narrow split, both columns remain inside the pane. The list can
        // always be collapsed using the transcript's header button.
        let width = showsConversations ? min(Self.listWidth, floor(max(0, bounds.width) * 0.4)) : 0
        let listFrame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        list.isHidden = !showsConversations
        divider.isHidden = !showsConversations
        if list.frame != listFrame { list.frame = listFrame }
        let dividerWidth: CGFloat = showsConversations ? min(1, max(0, bounds.width - width)) : 0
        divider.frame = CGRect(x: width, y: 0, width: dividerWidth, height: bounds.height)
        let transcriptFrame = CGRect(
            x: divider.frame.maxX,
            y: 0,
            width: max(0, bounds.width - divider.frame.maxX),
            height: bounds.height
        )
        if transcript?.frame != transcriptFrame { transcript?.frame = transcriptFrame }
    }

    // MARK: List

    private func connectList() {
        list.onNewConversation = { [weak self] in self?.newConversation() }
        let rows = list.list
        rows.onSelect = { [weak self] id in
            guard let id else { return }
            self?.select(ConversationID(id))
        }
        rows.onSetPinned = { [weak self] on, id in self?.setPinned(on, ConversationID(id)) }
        rows.onPlacePinned = { [weak self] id, index in self?.place(ConversationID(id), at: index) }
        rows.onSetRead = { [weak self] read, id in self?.setRead(read, ConversationID(id)) }
        rows.onDelete = { [weak self] id in self?.hide(ConversationID(id)) }
        let defaultID = ChiefService.shared.defaultConversationID.rawValue
        rows.canDelete = { id in id != defaultID }
        rows.menuItems = { [weak self] _ in
            [CmuxSidebarMenuItem(title: ChiefStrings.newConversation) { self?.newConversation() }]
        }
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
        let defaultID = ChiefService.shared.defaultConversationID
        let rows = rows.filter { Self.shouldShow($0.id, hidden: hiddenConversations, selected: selected, defaultID: defaultID) }
        let me = ChiefService.shared.me
        let avatar = listAvatar
        // A conversation on screen is being read: no dot, even before its read cursor lands.
        _ = ChiefService.shared.visibleGeneration
        let visible = ChiefService.shared.visibleConversations
        // Opening Home is an explicit read action even before AppKit has made the
        // window key. Keep the selected row quiet during the short interval before
        // HomeStore's asynchronous read cursor update reaches this projection.
        let selectedIsShown = Self.shouldMarkRead(isActive: isActive, attached: window != nil,
                                                  hidden: isHiddenOrHasHiddenAncestor)
        let pinned = pinnedOrder ?? rows.filter { $0.summary.pinRank != nil }
            .sorted { ($0.summary.pinRank ?? 0, $0.id.rawValue) < ($1.summary.pinRank ?? 0, $1.id.rawValue) }
            .map(\.id)
        let pinnedSet = Set(pinned)
        let entries = rows.map { row -> CmuxSidebarEntry in
            let others = row.summary.participants.filter { $0.id != me }
            let marked = unreadMarks.contains(row.id.rawValue)
            // While a card waits the row says what it waits on ("Needs your approval: …"), never the typing
            // dots (the Chief waits on the user); while a tool runs, its line; else the newest bubble.
            let waiting = ChiefService.shared.hasPendingApproval(row.id)
            let working = ChiefService.shared.isWorking(row.id)
            let line = ChiefService.shared.listPreview(for: row)
            return CmuxSidebarEntry(
                id: row.id.rawValue,
                title: row.title.isEmpty ? (others.first?.displayName ?? ChiefStrings.chiefName) : row.title,
                people: others.map { CmuxSidebarEntry.Person(id: $0.id.rawValue, name: $0.displayName, initials: $0.initials) },
                // No message yet: no time (the list draws none for `.distantPast`), as Messages shows a new thread.
                preview: Self.listPreview(row, line: line, waiting: waiting), previewSender: nil,
                lastAt: Self.hasNoMessages(row) ? .distantPast : row.timestamp,
                unreadCount: Self.unreadCount(rowID: row.id, rowUnread: row.unread, selected: selected,
                                              selectedIsShown: selectedIsShown, visible: visible, manuallyMarked: marked),
                pinned: pinnedSet.contains(row.id),
                typing: row.isTyping && !working,
                avatar: avatar)
        }
        // Pinned in their order first, then the rest newest first (the store's order).
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = pinned.compactMap { byID[$0.rawValue] } + entries.filter { !pinnedSet.contains(ConversationID($0.id)) }
        list.list.show(ordered, pinned: pinned.map(\.rawValue))
        onRowsChanged?(ordered)
        if list.list.selectedID != selected.rawValue {
            if byID[selected.rawValue] != nil {
                list.list.select(selected.rawValue)
            } else if !rows.isEmpty, ChiefService.shared.storeIfStarted?.isInboxCurrent == true {
                // The remembered conversation is gone: the default Chief's (after this pass).
                Task { @MainActor [weak self] in self?.select(ChiefService.shared.defaultConversationID) }
            }
        }
    }

    /// A conversation with no message and no send in flight.
    static func hasNoMessages(_ row: InboxRow) -> Bool {
        !row.isSending && row.summary.lastMessage == nil && row.previewAttachments == nil
            && row.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A row's preview line, as Messages draws it in a 1:1: the newest
    /// message's text with no sender prefix (MessagesLab's `SidebarStrings.preview`
    /// leaves `previewSender` out of a 1:1, mine included; cmux-next
    /// `InboxRow.homePreview`), the Chief's Markdown without its markers as
    /// the transcript shows it. An attachment-only message says so; a
    /// conversation with no message yet shows a quiet invitation (the list
    /// draws previews in the secondary color), so the row never has an empty
    /// second line.
    ///
    /// `line` is the conversation's ``ChiefListPreview`` (``ChiefService/listPreview(for:)``): a
    /// waiting card or a running tool says so, the newest bubble shows as its text, and a system
    /// row or finished tool call is never the preview. A pending send of mine wins over it.
    static func listPreview(_ row: InboxRow, line: ChiefListPreview.Line? = nil, waiting: Bool = false) -> String {
        let previewText = ChiefPreviewText()
        let waits = !row.isSending && (waiting || previewText.pendingApprovalPrompt(row.summary.lastMessage) != nil)
        if !row.isSending, let line {
            switch line {
            case .needsApproval(let text), .needsAnswer(let text): return text.replacingOccurrences(of: "\n", with: " ")
            case .running, .card, .message:
                // A card waits that the line has not read yet: say so, never the older line.
                if waits { return previewText.waitingForYou }
                if let text = line.text { return text.replacingOccurrences(of: "\n", with: " ") }
                if case .message(let message) = line { return messagePreview(message, in: row.summary) }
            }
        }
        // A waiting approval no line names yet: "Waiting for you", not its raw prompt.
        if waits { return previewText.waitingForYou }
        // InboxRow.preview is intentionally a cheap mirror projection. For Chief it can contain
        // a tool prompt or a question's option list while the richer tail read is still landing.
        // Never leak that implementation text into the sidebar. A pending send is the one case
        // where the projection is the user's own plain text and is safe to show immediately.
        if row.isSending {
            let text = row.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        }
        if let message = row.summary.lastMessage {
            let shown = messagePreview(message, in: row.summary)
            if !shown.isEmpty { return shown }
        }
        if row.previewAttachments != nil { return ChiefStrings.conversationAttachmentPreview }
        return ChiefStrings.conversationEmptyPreview
    }

    /// The sidebar count for a row while Home is mounted.
    ///
    /// The selected conversation is read as soon as it is shown. Its persisted
    /// cursor advances asynchronously, so this projection also suppresses the
    /// stale count until the store publishes the updated row. Other visible
    /// transcript panes use the same suppression through ``visible``.
    static func unreadCount(rowID: ConversationID, rowUnread: Int, selected: ConversationID,
                            selectedIsShown: Bool, visible: Set<ConversationID>, manuallyMarked: Bool) -> Int {
        if (selectedIsShown && rowID == selected) || visible.contains(rowID) { return 0 }
        return manuallyMarked ? max(rowUnread, 1) : rowUnread
    }

    /// A bubble's preview: its words as the transcript shows them (the Chief's Markdown flattened),
    /// else its attachment label.
    static func messagePreview(_ message: Message, in summary: ConversationSummary) -> String {
        let text = message.parts.compactMap { part -> String? in
            if case .text(let text, _) = part { return text }
            return nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return HomeMarkdownPreview(text, author: message.author, in: summary).text.replacingOccurrences(of: "\n", with: " ")
        }
        if let link = message.parts.lazy.compactMap({ part -> String? in
            if case .linkPreview(let link) = part { return link.title ?? link.url }
            return nil
        }).first { return link }
        return ChiefStrings.conversationAttachmentPreview
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

    /// Hides a conversation from this device's Home list when the sidebar's
    /// delete affordance, swipe action, or context-menu item is used. The
    /// selected conversation moves to the always-available Chief thread first,
    /// so the transcript never remains pointed at a removed row.
    private func hide(_ id: ConversationID) {
        guard id != ChiefService.shared.defaultConversationID else { return }
        hiddenConversations.insert(id.rawValue)
        defaults.set(hiddenConversations.sorted(), forKey: Self.hiddenConversationsKey)
        unreadMarks.remove(id.rawValue)
        saveUnreadMarks()
        if selected == id { select(ChiefService.shared.defaultConversationID) }
        else if let store = ChiefService.shared.storeIfStarted { showEntries(store.rows) }
    }

    /// Projection rule for the durable local archive. The default Chief thread
    /// is always available, and a selected row remains visible until selection
    /// moves so a reload cannot momentarily blank the transcript.
    static func shouldShow(_ id: ConversationID, hidden: Set<String>, selected: ConversationID,
                           defaultID: ConversationID) -> Bool {
        !hidden.contains(id.rawValue) || id == selected || id == defaultID
    }

    private func saveUnreadMarks() {
        defaults.set(unreadMarks.sorted(), forKey: Self.unreadMarksKey)
    }

    /// Whether Home may mark its selected conversation read now. The view must
    /// be mounted and active; key-window status belongs to transcript focus and
    /// is not required for the explicit act of opening a conversation.
    static func shouldMarkRead(isActive: Bool, attached: Bool, hidden: Bool) -> Bool {
        isActive && attached && !hidden
    }

    private func markSelectedReadIfShown() {
        guard Self.shouldMarkRead(isActive: isActive, attached: window != nil,
                                  hidden: isHiddenOrHasHiddenAncestor),
              let store = ChiefService.shared.storeIfStarted else { return }
        store.markRead(selected)
    }

    private func perform(_ op: HomeOp) {
        guard let store = ChiefService.shared.storeIfStarted else { return }
        // task-owner: one op; ends with its reply (a refusal leaves the list as the owner has it)
        Task { _ = try? await store.perform(op) }
    }

    /// Starts a new conversation with a new Chief and shows it (the Home
    /// row's compose button, the list's menu and the settings panel).
    func newConversation() {
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

    // MARK: Observation

    private func observeNotifications() {
        let center = NotificationCenter.default
        for name in [Notification.Name.ghosttyConfigDidReload, .ghosttyDefaultBackgroundDidChange,
                     CmuxAccentColor.didChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyCurrentAppearance() } // main-proof: observer on queue: .main
            })
        }
        observers.append(center.addObserver(forName: .cmuxChiefHomeDidActivate, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                self?.homeDidActivate(in: note.object as? NSWindow)
            }
        })
        observers.append(center.addObserver(forName: ChiefProfile.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self else { return }
                self.listAvatar = ChiefAvatarArtwork.listAvatar(ChiefAvatarArtwork.current())
                if let store = ChiefService.shared.storeIfStarted { self.showEntries(store.rows) }
            }
        })
    }

    /// Home became `window`'s content: the composer takes the keyboard, now
    /// or as soon as this view is in that window (the first entry mounts it).
    private func homeDidActivate(in window: NSWindow?) {
        guard let window, isActive else { return }
        if self.window === window {
            focusComposer()
        } else if self.window == nil {
            focusOnWindow = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        markSelectedReadIfShown()
        guard focusOnWindow, window != nil else { return }
        focusOnWindow = false
        focusComposer()
    }
}
