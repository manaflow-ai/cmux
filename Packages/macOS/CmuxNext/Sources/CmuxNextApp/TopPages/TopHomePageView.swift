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
        // Usage…, Archive Chief and Delete Chief… on a Chief's row; Hide or Show Alerts on a DM or group's row, and for a group
        // Group Info, Rename, Add People and Leave (the same actions as the palette and the CLI).
        list.menuItems = { id in
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
                return usage + bring + item("home.archiveChief", nil, ["chief": .string(chief.id)]) + delete
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
                items += item("home.renameConversation", nil, conversation)
                items += item("home.addMembers", nil, conversation)
                items += item("home.leaveConversation", nil, conversation)
            }
            return items
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
                rows = Self.visible(all, archivedChiefs: archived, me: store.me?.id)
                // A conversation came or went (a lease arrived, a request was accepted): requests may have changed.
                if Set(all.map(\.id)) != listed { listed = Set(all.map(\.id)); home.requests.refresh() }
                list.update(sidebar.model())
                if shown == nil, !isComposingNewMessage, let first = defaultConversation(rows: rows, home: home) { show(first) }
                // The cache's conversation of a Chief home made again (cx-ebm.55).
                if shownIsGone(store), let chief = Self.chief(home) { replaceGone(with: ConversationID(chief), store: store) }
            }
        }
        // task-owner: lives as long as this view; event-driven (Observation). The chief placed
        // on a paired server (G6) replaces the local chief while the page shows the local one.
        chiefObservation = Task { [weak self] in
            var previous = Self.chief(home)
            for await chief in ObservationStream({ Self.chief(home) }) {
                guard let self, let chief, chief != previous else { continue }
                if shownIsGone(home.homeStore) {
                    replaceGone(with: ConversationID(chief), store: home.homeStore)
                } else if shown == nil || shown?.rawValue == previous {
                    show(ConversationID(chief))
                }
                previous = chief
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

    /// The rows the list shows: an archived Chief's conversation is hidden
    /// (its history stays with the owner, read-only).
    static func visible(_ rows: [InboxRow], archivedChiefs: Set<String>, me: ParticipantID?) -> [InboxRow] {
        guard !archivedChiefs.isEmpty else { return rows }
        return rows.filter { row in
            guard row.kind == .chief else { return true }
            return !row.summary.participants.contains { $0.id != me && archivedChiefs.contains($0.id.rawValue) }
        }
    }

    /// The Chief's conversation (the chief placed on a server takes over a
    /// local one without history: `HomeChiefSource`), else the first listed conversation.
    private func defaultConversation(rows: [InboxRow], home: HomeService) -> ConversationID? {
        if let chief = Self.chief(home) { return ConversationID(chief) }
        return rows.homeLines.lazy.compactMap(\.conversation).first
    }

    static func chief(_ home: HomeService) -> String? {
        let local = HomeChiefName.select(from: home.conversations)
        return home.tabChiefs.chiefTab(local: local?.id, localHasHistory: (local?.lastSeq ?? 0) > 0, choice: home.hostedChief.choice)
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
        // Escape on an empty draft: back to the conversation shown before.
        page.onEscape = { [weak self] in
            guard let self else { return }
            endNewMessage()
            if let shown { list.select(shown) }
            focusPrimaryInput()
        }
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
    func conversationLeft(_ id: ConversationID, next: ConversationID?) {
        guard shown == id, let services else { return }
        let fallback = next.flatMap { $0 == id ? nil : $0 } ?? defaultConversation(rows: rows.filter { $0.id != id }, home: services.home)
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
        let panel = NSWindow(contentViewController: sheet)
        // The sheet draws in this page's scope (a room's own theme), not the app's: its labels
        // resolved before the sheet had a parent.
        panel.adoptThemeScope(of: self)
        window.beginSheet(panel)
    }
}
