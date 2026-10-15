import AppKit
import CmuxFoundation
import CmuxHomeCore
import MessagesLabHome
import MessagesLabSidebar
import Observation

/// Chief Home for one main window. While Home is selected the window's left
/// sidebar becomes the conversation list (``list``, hosted under the pinned
/// Chief row, as cmux-next's rail item swaps its one navigation column and as
/// Messages has one list beside one transcript), and this view, the content
/// area, shows the selected conversation's ``ChiefTranscriptView``. There is no
/// third column.
///
/// The window keeps one instance for its lifetime (`ContentView`): the list
/// and the transcript are two views of the same selection, and leaving Home
/// keeps the draft and scroll position.
@MainActor
final class ChiefHomeView: NSView {
    private static let selectionKey = "chief.home.selectedConversation"
    private static let unreadMarksKey = "chief.home.unreadMarks"

    /// The conversation list the sidebar hosts while Home is selected.
    let list = ChiefConversationListView()
    private(set) var transcript: ChiefTranscriptView?
    private(set) var selected: ConversationID
    private var stopped = false
    // SAFETY: written only on the main actor; `deinit` reads it once no other
    // reference exists, and NotificationCenter removal is thread-safe.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    /// Conversations the user marked unread (the owner's read cursor only moves forward).
    private var unreadMarks: Set<String>
    private let defaults: UserDefaults
    /// The Chief's avatar as the list draws it (``ChiefAvatarArtwork``).
    private var listAvatar: CmuxSidebarEntry.Avatar?
    /// Home was activated before this view joined its window (first entry):
    /// the composer takes focus once it does.
    private var focusOnWindow = false

    /// Whether the host shows Home now; a hidden Home sends no read receipts.
    var isActive = true { didSet { transcript?.isActive = isActive } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let service = ChiefService.shared
        service.start()
        selected = defaults.string(forKey: Self.selectionKey).map { ConversationID($0) } ?? service.defaultConversationID
        unreadMarks = Set(defaults.stringArray(forKey: Self.unreadMarksKey) ?? [])
        super.init(frame: .zero)
        connectList()
        observeNotifications()
        listAvatar = ChiefAvatarArtwork.listAvatar(ChiefAvatarArtwork.current())
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
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        transcript = view
        if hadFocus { view.focusComposer() }
    }

    // MARK: List

    private func connectList() {
        let rows = list.list
        rows.onSelect = { [weak self] id in
            guard let id else { return }
            self?.select(ConversationID(id))
        }
        rows.onSetPinned = { [weak self] on, id in self?.setPinned(on, ConversationID(id)) }
        rows.onPlacePinned = { [weak self] id, index in self?.place(ConversationID(id), at: index) }
        rows.onSetRead = { [weak self] read, id in self?.setRead(read, ConversationID(id)) }
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
        let me = ChiefService.shared.me
        let avatar = listAvatar
        // A conversation on screen is being read: no dot, even before its read cursor lands.
        let visible = ChiefService.shared.visibleConversations
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
                preview: Self.listPreview(row), previewSender: nil, lastAt: row.timestamp,
                unreadCount: marked ? max(row.unread, 1) : (visible.contains(row.id) ? 0 : row.unread), pinned: pinnedSet.contains(row.id), typing: row.isTyping,
                avatar: avatar)
        }
        // Pinned in their order first, then the rest newest first (the store's order).
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = pinned.compactMap { byID[$0.rawValue] } + entries.filter { !pinnedSet.contains(ConversationID($0.id)) }
        list.list.show(ordered, pinned: pinned.map(\.rawValue))
        if list.list.selectedID != selected.rawValue {
            if byID[selected.rawValue] != nil {
                list.list.select(selected.rawValue)
            } else if !rows.isEmpty, ChiefService.shared.storeIfStarted?.isInboxCurrent == true {
                // The remembered conversation is gone: the default Chief's (after this pass).
                Task { @MainActor [weak self] in self?.select(ChiefService.shared.defaultConversationID) }
            }
        }
    }

    /// A row's preview line, as Messages draws it in a 1:1: the newest
    /// message's text with no sender prefix (MessagesLab's `SidebarStrings.preview`
    /// leaves `previewSender` out of a 1:1, mine included; cmux-next
    /// `InboxRow.homePreview`), the Chief's Markdown without its markers as
    /// the transcript shows it. An attachment-only message says so; a
    /// conversation with no message yet shows a quiet invitation (the list
    /// draws previews in the secondary color), so the row never has an empty
    /// second line.
    static func listPreview(_ row: InboxRow) -> String {
        // A waiting approval says what it asks ("Needs your approval: <command>"), not its raw prompt.
        if !row.isSending, let prompt = ChiefPreviewText.pendingApprovalPrompt(row.summary.lastMessage) {
            return ChiefPreviewText.approval(prompt: prompt)
        }
        let text = row.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // A pending send is mine (plain text); the newest message keeps its author's rule.
            let author = row.isSending ? nil : row.summary.lastMessage?.author
            let shown = author.map { HomeMarkdownPreview(text, author: $0, in: row.summary).text } ?? text
            return shown.replacingOccurrences(of: "\n", with: " ")
        }
        if row.previewAttachments != nil { return ChiefStrings.conversationAttachmentPreview }
        return ChiefStrings.conversationEmptyPreview
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
        guard focusOnWindow, window != nil else { return }
        focusOnWindow = false
        focusComposer()
    }
}
