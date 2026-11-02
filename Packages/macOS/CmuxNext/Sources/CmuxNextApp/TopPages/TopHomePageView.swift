import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextChiefMemory
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import Observation

/// The Home top page, two columns: MessagesLab's conversation list
/// (`HomeSidebarView` over `HomeSidebarSource`: search, the pinned grid with
/// the Chiefs, then conversations newest first) on the left, and the chosen conversation's native transcript
/// (`HomeHostView`, MessagesLab's code) on the right. The page opens on the
/// Chief conversation when there is one, else on the newest conversation.
/// The store's home workspace and its chief tab stay as they are (other
/// clients read them); this page reads the same store.
@MainActor
final class TopHomePageView: NSView {
    private weak var services: AppServices?
    let list = HomeSidebarView()
    /// The sidebar's data (pins, search, the Messages-style model).
    let sidebar: HomeSidebarSource
    let transcriptColumn = NSView()
    let split: HomeSidebarSplitView
    /// The rows shown (archived Chiefs hidden), for `debug.home page`.
    private(set) var rows: [InboxRow] = []
    var lines: [HomeConversationLine] { rows.homeLines }
    private(set) var host: HomeHostView?
    private(set) var shown: ConversationID?
    /// The New Message page (Messages' New Message: a page, not a sheet).
    /// Kept while hidden when the person typed something, with its row in the list.
    private(set) var newMessage: HomeNewMessageView?
    /// The New Message page is the one on screen.
    var isComposingNewMessage: Bool { newMessage.map { !$0.isHidden } ?? false }
    /// A conversation the person started that the inbox does not list yet: opened (with the
    /// keyboard in its box) when it shows.
    private var opening: ConversationID?
    private var rowsObservation: Task<Void, Never>?
    private var selectionObservation: Task<Void, Never>?
    private var chiefObservation: Task<Void, Never>?
    /// The conversation the page opened by itself, which a later Chief replaces (``followUp``).
    /// What the person picked is never this, so it is never taken off them: ``show(_:)`` clears it
    /// and only the two observations that open one themselves set it again.
    private(set) var followedChief: String?
    private var accountObservation: Task<Void, Never>?
    private var requestsObservation: Task<Void, Never>?
    private var unreadColorObservation: Task<Void, Never>?

    init(services: AppServices, windowKey: @escaping () -> String) {
        self.services = services
        sidebar = services.home.makeSidebarSource()
        split = HomeSidebarSplitView(sidebar: list, content: transcriptColumn)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.topPage.home")
        split.windowKey = windowKey
        split.frame = bounds
        split.autoresizingMask = [.width, .height]
        addSubview(split)
        wireList(services)
        observe(services.home)
        // task-owner: lives as long as this view; one read of the team and Chiefs
        Task { await services.home.directory.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        rowsObservation?.cancel()
        selectionObservation?.cancel()
        chiefObservation?.cancel()
        accountObservation?.cancel()
        requestsObservation?.cancel()
        unreadColorObservation?.cancel()
    }

    /// Redraws the list after a pin change (`home.togglePin`).
    func listPinsChanged() {
        list.update(sidebar.model())
    }

    private func wireList(_ services: AppServices) {
        let sidebar = sidebar
        // Opening a conversation from the list reads it, so a Mark as Unread ends there.
        list.onSelect = { [weak self] id in
            if id != HomeSidebarView.draftRowID { sidebar.setMarkedUnread(false, id) }
            self?.show(id)
        }
        // A plain click on a row or pinned tile (the open one too), or Return: the message box takes the keyboard.
        list.onOpen = { [weak self] id in
            if id != HomeSidebarView.draftRowID { sidebar.setMarkedUnread(false, id) }
            self?.open(id)
        }
        // The list redraws in the same turn, so a dropped tile lands from where it was drawn.
        // The New Message row is no conversation: it never pins or takes a mark.
        // Pin/Unpin on a row and a tile dragged out of the grid run the one pin action (palette, CLI, MCP).
        list.onSetPinned = { [weak self] on, id in
            guard id != HomeSidebarView.draftRowID else { return }
            let arguments: [String: ActionValue] = ["conversation": .string(id.rawValue), "pinned": .bool(on)]
            _ = services.registry.perform("home.togglePin", invocation: ActionInvocation(arguments: arguments, origin: .user))
            self?.listPinsChanged()
        }
        list.onPlacePinned = { [weak self] id, index in
            guard id != HomeSidebarView.draftRowID else { return }
            sidebar.place(id, at: index)
            self?.list.update(sidebar.model())
        }
        let home = services.home
        let registry = services.registry
        // Mark as Read: the user's unread mark goes, and the read cursor moves to the newest message.
        list.onMarkRead = { id in
            sidebar.setMarkedUnread(false, id)
            guard let row = home.homeStore.rows.first(where: { $0.id == id }), row.unread > 0 else { return }
            let store = home.homeStore
            // task-owner: one op; ends with the owner's answer
            Task { _ = try? await store.perform(.setReadCursor(conversation: id, seq: row.summary.lastSeq)) }
        }
        list.onMarkUnread = { id in if id != HomeSidebarView.draftRowID { sidebar.setMarkedUnread(true, id) } }
        // Conversation Info (sharing a Cloud Chief), Usage…, Archive Chief and Delete Chief… on a Chief's row; Hide or Show Alerts on a DM or group's row, and for a group
        // Group Info, Rename, Add People and Leave (the same actions as the palette and the CLI).
        let chatMenu: @MainActor (ConversationID) -> [NSMenuItem] = { id in
            guard let row = home.homeStore.rows.first(where: { $0.id == id }) else { return [] }
            @MainActor func item(_ action: ActionID, _ title: String? = nil, _ arguments: [String: ActionValue] = [:]) -> [NSMenuItem] {
                guard let title = title ?? registry.title(for: action) else { return [] }
                return [HomeSidebarView.menuItem(title) {
                    _ = registry.perform(action, invocation: ActionInvocation(arguments: arguments, origin: .user))
                }]
            }
            if row.kind == .chief {
                // Chief Usage (chief.openUsage) reads this Mac's Chiefs: left out in a build without one.
                let usage = registry.unavailableReason(for: ChiefUsagePageTab.actionID) == nil
                    ? item(ChiefUsagePageTab.actionID, ChiefUsagePageTab.menuTitle) : []
                // Delete for any Chief but the default one; Archive for a cloud Chief (this Mac's have no archive).
                let delete = home.deletableChief(of: row).map { item("home.deleteChief", nil, ["chief": .string($0.id)]) } ?? []
                // Import Memories… (chief.importMemories): into this Mac's Chief, or into the Cloud Chief the row is.
                let cloudChief = row.summary.participants.lazy.compactMap({ home.directory.chief(for: $0.id) }).first
                let bring = item(ChiefMemoryImportHandlers.actionID, nil, cloudChief.map { ["chief": .string($0.id)] } ?? [:])
                guard let chief = cloudChief else { return usage + bring + delete }
                // A Cloud Chief's conversation is shared with teammates from its info (Add People…).
                let info = item("home.conversationInfo", nil, ["conversation": .string(id.rawValue)])
                return info + usage + bring + item("home.archiveChief", nil, ["chief": .string(chief.id)]) + delete
            }
            let conversation: [String: ActionValue] = ["conversation": .string(id.rawValue)]
            let actions = home.groupActions
            var items: [NSMenuItem] = []
            if row.kind == .group {
                items += item("home.conversationInfo", HomeGroupInfo.groupInfoMenuTitle, conversation)
            }
            if actions.info(id)?.canMute == true {
                let muted = actions.info(id)?.muted == true
                items += item(muted ? "home.unmuteConversation" : "home.muteConversation", nil, conversation)
            }
            if row.kind == .group {
                // Someone else's Chief conversation shared with me: its owner names it and adds people.
                if row.summary.declaredKind != .chief {
                    items += item("home.renameConversation", nil, conversation)
                    items += item("home.addMembers", nil, conversation)
                }
                items += item("home.leaveConversation", nil, conversation)
            }
            return items
        }
        // Chat Colors… on every chat (Chiefs, DMs and groups): its own bubble and text colours.
        list.menuItems = { id in
            let items = chatMenu(id)
            guard home.homeStore.rows.contains(where: { $0.id == id }), let title = registry.title(for: "home.chatColors") else { return items }
            let colors = HomeSidebarView.menuItem(title) {
                _ = registry.perform("home.chatColors", invocation: ActionInvocation(arguments: ["conversation": .string(id.rawValue)], origin: .user))
            }
            return items + [colors]
        }
        // Delete Conversation… and a row's left swipe: asks as Messages does, then takes it off the list
        // (`home.hideConversation`; a newer message or Show Hidden Conversations lists it again).
        list.onDelete = { [weak self] id in
            guard id != HomeSidebarView.draftRowID, home.homeStore.rows.contains(where: { $0.id == id }) else { return }
            HomeListActions.confirmDelete(in: self?.window) {
                _ = registry.perform("home.hideConversation", invocation: ActionInvocation(arguments: ["conversation": .string(id.rawValue)], origin: .user))
            }
        }
        // Search: teammates with no DM yet, under the conversations; choosing one starts the DM.
        list.teammates = { [weak sidebar] query in
            guard let sidebar else { return [] }
            return HomeSidebarModel(rows: home.homeStore.rows, pins: sidebar.pins, me: home.homeStore.me?.id, query: query,
                                    contacts: home.contacts()).people
        }
        list.onStartTeammate = { [weak self] person in
            // task-owner: one conversation start; ends with the owner's answer
            Task { [weak self] in
                guard case .opened(let id) = await home.startConversation([.contact(person)], title: "") else { return }
                self?.openWhenListed(id)
            }
        }
        list.onNewMessage = { [weak self] in self?.presentNewMessage() }
        list.onCloseDraft = { [weak self] in self?.performCloseNewMessage() }
        list.onOpenRequests = { [weak self] in self?.presentRequests() }
        list.composeMenu = { [weak services] in services.map { HomePageMenus.backgroundMenu(registry: $0.registry) } }
    }

    /// Follows the inbox rows (Observation) and the conversation an action
    /// asked to show once it is listed.
    private func observe(_ home: HomeService) {
        let store = home.homeStore
        // task-owner: lives as long as this view; event-driven (Observation)
        let sidebar = sidebar
        rowsObservation = Task { [weak self] in
            // The Chiefs listed when their engines (the rows' badges) were last read.
            var badgedChiefs: Set<String>?
            var listed: Set<ConversationID> = []
            // The owner's rows when the Chiefs' pictures were last read: a chief-changed event
            // (a picture set by a tool or the CLI) reads the rows again, and the pictures with them.
            var picturedRows: [HomeInboxRequest.Response?]?
            var picturedChiefs: Set<String>?
            // Each Chief's pet character is its avatar when it has none of its own: a new pick redraws the list.
            for await (all, archived, _, _, _, _, owned, _, _, _, _, _) in ObservationStream({
                (store.rows, home.directory.archivedChiefs, sidebar.query, sidebar.pins, sidebar.unreadMarks, home.chiefFaces,
                 sidebar.ownerRows, home.directory.chiefHarnesses, home.chiefRoster, home.services.settings?.snapshot.homeChiefPetMascot,
                 // The team is read after the page opens: its teammates are rows once it lands.
                 home.directory.teamMembers,
                 // A rename of a Chief redraws its tile.
                 home.chiefNames)
            }) {
                guard let self else { return }
                let chiefs = Set(all.flatMap { $0.summary.participants.filter(\.isChief).map(\.id.rawValue) })
                if chiefs != badgedChiefs {
                    badgedChiefs = chiefs
                    home.refreshChiefHarnesses()
                }
                if owned != picturedRows || chiefs != picturedChiefs {
                    picturedRows = owned
                    picturedChiefs = chiefs
                    home.refreshChiefAvatars()
                }
                rows = HomeArchivedChiefs(archived, me: store.me?.id).visible(all)
                // A conversation came or went (a lease arrived, a request was accepted): requests may have changed.
                if Set(all.map(\.id)) != listed { listed = Set(all.map(\.id)); home.requests.refresh() }
                list.update(sidebar.model())
                // Archive Chief on the conversation that shows: the default conversation takes its place.
                if let shown, Self.isHidden(shown, rows: rows, home: home) { conversationLeft(shown, next: nil) }
                if shown == nil, !isComposingNewMessage, let first = Self.defaultConversation(rows: rows, home: home) {
                    show(first)
                    // The page opened it, not the person, so a Chief that arrives later replaces it.
                    followedChief = first.rawValue
                }
                // The cache's conversation of a Chief home made again (cx-ebm.55).
                if shownIsGone(store), let chief = Self.chief(home) { replaceGone(with: ConversationID(chief), store: store) }
            }
        }
        // task-owner: lives as long as this view; event-driven (Observation). The chief placed
        // on a paired server (G6) replaces the local chief while the page shows the local one.
        followedChief = Self.chief(home)
        chiefObservation = Task { [weak self] in
            var last = Self.chiefKey(home)
            for await key in ObservationStream({ Self.chiefKey(home) }) {
                guard let self, key != last else { continue }
                last = key
                let chief = key.chief
                if let chief, shownIsGone(home.homeStore) {
                    replaceGone(with: ConversationID(chief), store: home.homeStore)
                    followedChief = chief
                    continue
                }
                let next = Self.followUp(chief: chief, shown: shown, followed: followedChief,
                                         composing: isComposingNewMessage, rows: rows, home: home)
                // After the open, which clears it: every other ``show(_:)`` is the person's.
                if let open = next.open { show(open) }
                followedChief = next.followed
            }
        }
        let auth = home.services.cloud.auth
        // task-owner: lives as long as this view; event-driven (Observation). Another account has its own pins.
        accountObservation = Task {
            for await _ in ObservationStream({ auth.user?.id }) { sidebar.reloadPins() }
        }
        // task-owner: lives as long as this view; event-driven (Observation)
        requestsObservation = Task { [weak self] in
            for await count in ObservationStream({ home.requests.items.count }) { self?.list.showRequests(count) }
        }
        // task-owner: lives as long as this view; event-driven (Observation). The unread dot is
        // the unread rings' color (`notifications.attention.color`, nil: the notification blue).
        unreadColorObservation = Task { [weak self] in
            for await color in ObservationStream({ home.services.settings?.snapshot.attention.color }) {
                self?.list.unreadDotColor = color?.nsColor
            }
        }
        // task-owner: lives as long as this view; event-driven (Observation)
        selectionObservation = Task { [weak self] in
            for await pending in ObservationStream({ (home.pendingSelection, store.rows.map(\.id)) }) {
                guard let self, let id = pending.0, pending.1.contains(id) else { continue }
                home.pendingSelection = nil
                show(id)
                if opening == id {
                    opening = nil
                    host?.takeKeyboardOnOpen()
                }
            }
        }
    }

    /// The Chief's conversation (the chief placed on a server takes over a
    /// local one without history: `HomeChiefSource`), else the first listed conversation that the
    /// Engine row does not exclude (with This Mac chosen, never a cloud Chief's: ``HomeService/excludedChiefConversations``).
    static func defaultConversation(rows: [InboxRow], home: HomeService) -> ConversationID? {
        if let chief = Self.chief(home) { return ConversationID(chief) }
        let excluded = home.excludedChiefConversations
        return rows.homeLines.lazy.compactMap(\.conversation).first { !excluded.contains($0.rawValue) }
    }

    /// An archived Chief's conversation: listed by the store, left out of `rows` (``HomeArchivedChiefs``).
    static func isHidden(_ id: ConversationID, rows: [InboxRow], home: HomeService) -> Bool {
        home.homeStore.rows.contains { $0.id == id } && !rows.contains { $0.id == id }
    }

    /// What the Chief observation watches: the preferred Chief and whether this Mac's Chief is the
    /// choice. The Engine row changes the choice while the preferred Chief stays nil (the cloud
    /// read has not landed and this Mac's Chief is not listed yet), and the page must reconcile
    /// what it opened by itself then too, so the choice is part of what it watches.
    struct ChiefKey: Equatable {
        var chief: String?
        var prefersLocal: Bool
    }

    static func chiefKey(_ home: HomeService) -> ChiefKey {
        ChiefKey(chief: chief(home), prefersLocal: home.prefersLocalChief)
    }

    /// What the page does when the preferred Chief changes, and which Chief it follows afterwards.
    struct ChiefFollowUp: Equatable {
        /// The conversation to open; nil: what is shown stays.
        var open: ConversationID?
        /// The Chief conversation the page opened by itself, which a later Chief replaces. What the
        /// person picked themselves is never replaced, so it is not this.
        var followed: String?
    }

    /// The preferred Chief is now `chief` (``HomeService/defaultChiefConversation``), the page
    /// shows `shown`, and `followed` is what it last opened by itself. Pure, so the whole
    /// transition is under test: the Engine row's switch to This Mac goes through a stretch with no
    /// Chief at all, and the Chief that arrives after it must still open.
    static func followUp(chief: String?, shown: ConversationID?, followed: String?, composing: Bool,
                         rows: [InboxRow], home: HomeService) -> ChiefFollowUp {
        // Only what the page opened itself is ever replaced: the conversation the person picked
        // stays, and so does the New Message page, which `show(_:)` would leave.
        let mine = !composing && (shown == nil || shown?.rawValue == followed)
        guard let chief else {
            // No Chief to open: This Mac was picked while its Chief is not listed yet. The cloud
            // Chief on screen is one the Engine row now excludes, so the page leaves it for the
            // first conversation the row allows. `followed` stays whatever it was, so the Chief
            // that arrives next still replaces what this left behind.
            guard mine, let next = replacementForExcluded(shown: shown, rows: rows, home: home) else {
                // Nothing the row allows is listed, the person is on a conversation of their own,
                // or the New Message page is up: what is shown stays, rather than leave an empty
                // window or take the person off what they opened.
                return ChiefFollowUp(open: nil, followed: followed)
            }
            return ChiefFollowUp(open: next, followed: next.rawValue)
        }
        // Following only what it actually opened: a Chief it left the person alone for is not
        // theirs to be taken off later. Auto makes that sequence ordinary — the person opens the
        // Hosted Chief while this Mac's brain runs, that brain dies so Hosted becomes preferred
        // (nothing opens, they are already there), and its restart must not move them.
        guard mine else { return ChiefFollowUp(open: nil, followed: followed) }
        return ChiefFollowUp(open: ConversationID(chief), followed: chief)
    }

    /// What the page shows once there is no Chief conversation at all: the first conversation the
    /// Engine row allows, but only when what is shown is one it excludes (a cloud Chief after This
    /// Mac was picked). nil: what is shown stays, which is every other case.
    static func replacementForExcluded(shown: ConversationID?, rows: [InboxRow], home: HomeService) -> ConversationID? {
        guard let shown, home.excludedChiefConversations.contains(shown.rawValue),
              let next = defaultConversation(rows: rows, home: home), next != shown else { return nil }
        return next
    }

    /// The preferred Chief's conversation, unless Archive Chief hid it (``HomeArchivedChiefs/openable(_:listed:)``).
    static func chief(_ home: HomeService) -> String? {
        HomeArchivedChiefs(home.directory.archivedChiefs, me: home.homeStore.me?.id)
            .openable(home.defaultChiefConversation, listed: home.homeStore.rows)
    }

    /// The shown conversation is one the owner's own inbox does not have:
    /// the cache's conversation of a Chief home made again at the same path
    /// (cx-ebm.55). Decided only on the owner's inbox, never the cache's copy.
    private func shownIsGone(_ store: HomeStore) -> Bool {
        guard let shown else { return false }
        return store.isInboxCurrent && store.isCacheOnly(shown)
    }

    /// Shows the live Chief instead of a gone conversation; the text and pictures the user
    /// put there go with it (after the Chief's own draft), so nothing typed or pasted is lost.
    private func replaceGone(with chief: ConversationID, store: HomeStore) {
        guard let gone = shown, gone != chief, store.summary(chief) != nil else { return }
        let pictures = store.draftAttachments(for: gone)
        if !pictures.isEmpty {
            let own = store.draftAttachments(for: chief)
            store.setDraftAttachments(own + pictures.filter { p in !own.contains { $0.ref.hash == p.ref.hash } }, for: chief)
            store.setDraftAttachments([], for: gone)
        }
        let text = store.draft(for: gone) ?? ""
        if !text.isEmpty {
            let own = store.draft(for: chief) ?? ""
            store.setDraft(own.isEmpty ? text : own + "\n" + text, for: chief)
            store.setDraft("", for: gone)
        }
        // Its view says the Chief restarted and that Return sends what was carried.
        if !text.isEmpty || !pictures.isEmpty { store.noteCarriedDraft(to: chief) }
        show(chief)
    }

    /// Shows `id` in the transcript column and selects it in the list (the
    /// New Message row shows the New Message page).
    func show(_ id: ConversationID) {
        // Whatever the page was following, it is not following it now. The two observations that
        // open a conversation by themselves set ``followedChief`` again right after this call, so
        // every other way in here (the list, the palette, an action, a close's neighbour) is the
        // person's choice and a Chief that arrives later leaves it alone.
        followedChief = nil
        guard id != HomeSidebarView.draftRowID else { return presentNewMessage() }
        list.select(id)
        let leftNewMessage = leaveNewMessage()
        guard id != shown, let services else {
            if leftNewMessage { focusPrimaryInput() }
            return
        }
        shown = id
        host?.removeFromSuperview()
        let view = HomeHostView(services: services, conversation: id.rawValue)
        view.isHidden = isComposingNewMessage
        view.frame = transcriptColumn.bounds
        view.autoresizingMask = [.width, .height]
        transcriptColumn.addSubview(view)
        host = view
        services.home.homeDidOpen(asked: true)
        if window?.firstResponder === window || window?.firstResponder == nil { focusPrimaryInput() }
    }

    /// The person opened `id` (a click on its row or pinned tile, the shown one too; Return in the
    /// list; the previous/next conversation keys; a conversation they started): shown, and its
    /// message box takes the keyboard, as Messages' message field does. One path for every
    /// entry point; `show` alone never moves a keyboard the person put somewhere.
    func open(_ id: ConversationID) {
        show(id)
        guard shown == id else { return }
        host?.takeKeyboardOnOpen()
    }

    /// A conversation the person just started or made (a teammate from search, a sheet): opened
    /// now when listed, else once the inbox lists it (`pendingSelection`).
    func openWhenListed(_ id: ConversationID) {
        guard let services else { return }
        if services.home.homeStore.rows.contains(where: { $0.id == id }) {
            open(id)
        } else {
            opening = id
            services.home.pendingSelection = id
        }
    }

    /// A permalink: its conversation, and its message's thread at its branch (any depth).
    func show(_ link: HomeDockSelection) { show(ConversationID(link.conversation)); if let m = link.message, let host { HomePageTab.transcript(in: host)?.reveal(message: m) } }

    /// Home's primary input (the message box; To: on the New Message page) takes the keyboard:
    /// the message box at once or, while the shown conversation's first page loads, once it exists.
    func focusPrimaryInput() {
        if isComposingNewMessage {
            if let target = newMessage?.focusTarget { window?.makeFirstResponder(target) }
            return
        }
        host?.takeKeyboardOnOpen()
    }

    // MARK: New Message

    /// New Message (the compose button, the palette, the
    /// File menu, `cmux action run home.newMessage`): a selected "New
    /// Message" row at the top of the list and the New Message page in the
    /// transcript column, with the caret in To:. A kept draft comes back as
    /// the person left it.
    func presentNewMessage() {
        guard let services else { return }
        let page = newMessage ?? makeNewMessage(services)
        if page.superview == nil {
            page.frame = transcriptColumn.bounds
            page.autoresizingMask = [.width, .height]
            transcriptColumn.addSubview(page)
        }
        page.isHidden = false
        host?.isHidden = true
        split.composing = true
        list.setDraftRow(HomeNewMessageDraft.rowTitle)
        list.select(HomeSidebarView.draftRowID)
        page.needsLayout = true
        page.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(page.focusTarget)
    }

    private func makeNewMessage(_ services: AppServices) -> HomeNewMessageView {
        let page = HomeNewMessageView(services: services)
        // The first send made the conversation: the draft ends and the page shows it.
        page.onSent = { [weak self] id in
            // task-owner: one hop out of the draft store's send before the page goes
            Task { @MainActor [weak self] in
                guard let self else { return }
                endNewMessage()
                openWhenListed(id)
            }
        }
        // Escape in an empty To: field: the same close as the row's x (`home.closeNewMessage`).
        page.onEscape = { [weak self] in self?.performCloseNewMessage() }
        newMessage = page
        return page
    }

    /// Hides the New Message page for another conversation. An empty draft
    /// goes with its row (Messages drops an untouched New Message); one with
    /// recipients or text stays, its row unselected. True when it showed.
    @discardableResult
    private func leaveNewMessage() -> Bool {
        guard let page = newMessage, !page.isHidden else { return false }
        if page.isEmpty {
            endNewMessage()
        } else {
            page.isHidden = true
            host?.isHidden = false
            split.composing = false
        }
        return true
    }

    /// `home.closeNewMessage`: the draft, its page and its row go, whatever was typed (Messages' x);
    /// the conversation shown before comes back, with the keyboard only when the page had it.
    func closeNewMessage() {
        guard let page = newMessage else { return }
        let (wasShowing, hadKeyboard) = (!page.isHidden, (window?.firstResponder as? NSView)?.isDescendant(of: page) == true)
        endNewMessage()
        if wasShowing, let shown { list.select(shown) }
        if wasShowing, hadKeyboard { focusPrimaryInput() }
    }

    /// Runs `home.closeNewMessage` through the registry (one path for every entrypoint).
    private func performCloseNewMessage() { _ = services?.registry.perform("home.closeNewMessage", invocation: ActionInvocation(origin: .user)) }

    /// Drops the New Message draft, its page and its row.
    private func endNewMessage() {
        guard let page = newMessage else { return }
        newMessage = nil
        page.stop()
        page.removeFromSuperview()
        host?.isHidden = false
        split.composing = false
        list.setDraftRow(nil)
    }

    // MARK: Sheets

    func presentInvite(prefill: String) {
        guard let services else { return }
        let home = services.home
        let pending = home.homeStore.rows.pendingInvites.map(\.contact)
        let sheet = HomeInviteSheet(prefill: prefill, pending: pending)
        sheet.onSend = { address in await home.invite(address) }
        present(sheet)
    }

    /// Message Requests: Accept opens the conversation; Decline and Block stay silent to the sender.
    func presentRequests() {
        guard let services else { return }
        let requests = services.home.requests
        let sheet = HomeRequestsSheet(requests: requests.items)
        sheet.onAnswer = { id, answer in await requests.answer(id, answer) }
        present(sheet)
        requests.refresh()
    }

    func presentNewChief() {
        guard let services else { return }
        let home = services.home
        let sheet = HomeNewChiefSheet()
        sheet.onCreate = { name, backend in await home.createChief(named: name, backend: backend) }
        present(sheet)
    }

    /// The group info sheet for `id` (a DM or group): name, members, Add People, Hide Alerts and
    /// Leave, each through `HomeService.groupActions` (Leave through its action, which asks first).
    /// It follows the conversation while it shows.
    func presentGroupInfo(_ id: ConversationID) {
        guard let services, let window else { return }
        let actions = services.home.groupActions
        guard let info = actions.info(id) else { return services.registry.refuse(HomeGroupOutcome.unknownConversation.message ?? "") }
        let registry = services.registry
        let model = HomeGroupInfoModel(info: info, addable: actions.addable(to: id), actions: HomeGroupInfoActions(
            rename: { await actions.rename(id, to: $0) },
            add: { await actions.add($0, to: id, naming: $1) },
            remove: { await actions.remove($0, from: id) },
            setMuted: { actions.setMuted($0, id) },
            leave: {
                _ = registry.perform("home.leaveConversation",
                                     invocation: ActionInvocation(arguments: ["conversation": .string(id.rawValue)], origin: .user))
            },
            inviteByEmail: { [weak self] in self?.presentInvite(prefill: "") },
            setChiefReplies: { await actions.setChiefReplies($0, id) }))
        let sheet = HomeGroupInfoSheet(model: model, colors: performWithTheme { HomeGroupInfoColors.resolve() })
        // task-owner: lives while the sheet shows; event-driven (Observation): members, name and mute as the owner says
        let watch = Task { [weak sheet] in
            for await info in ObservationStream({ actions.info(id) }) {
                guard let info else { sheet?.close(); return }
                model.update(info: info, addable: actions.addable(to: id))
            }
        }
        sheet.onClose = { watch.cancel() }
        let panel = NSWindow(contentViewController: sheet)
        panel.adoptThemeScope(of: self)
        window.beginSheet(panel)
    }

    /// I left `id` while it showed: its neighbor in the list shows (else the default conversation).
    /// A neighbor the Engine row excludes (a cloud Chief under This Mac) is not one: the default
    /// conversation decides instead.
    func conversationLeft(_ id: ConversationID, next: ConversationID?) {
        guard shown == id, let services else { return }
        let excluded = services.home.excludedChiefConversations
        let neighbor = next.flatMap { $0 == id || excluded.contains($0.rawValue) ? nil : $0 }
        let fallback = neighbor ?? Self.defaultConversation(rows: rows.filter { $0.id != id }, home: services.home)
        guard let fallback, fallback != id else { return }
        show(fallback)
    }

    private func present(_ sheet: HomeSheetController) {
        sheet.onFinish = { [weak self] id in
            guard let self, let id else { return }
            // Opened now when listed; else once the inbox lists it.
            openWhenListed(id)
        }
        guard let window else { return }
        HomeSheetPresenter().present(sheet, over: window, themeSource: self)
    }
}

extension TopHomePageView: HomeListPage {}
