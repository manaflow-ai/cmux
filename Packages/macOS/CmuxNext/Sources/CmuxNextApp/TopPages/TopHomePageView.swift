import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextChiefMemory
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextWakeups
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
    private(set) weak var services: AppServices?
    let list = HomeSidebarView()
    /// The sidebar's data (pins, search, the Messages-style model).
    let sidebar: HomeSidebarSource
    let transcriptColumn = NSView()
    let split: HomeSidebarSplitView
    /// The rows shown (archived Chiefs hidden), for `debug.home page`.
    private(set) var rows: [InboxRow] = []
    var lines: [HomeConversationLine] { rows.homeLines }
    private(set) var host: HomeHostView?
    /// The conversation of the transcript column, also while the New Message page covers it. Observed, as
    /// ``isComposingNewMessage`` is (the page is not a model, so by hand).
    private(set) var shown: ConversationID? {
        get {
            observation.access(self, keyPath: \.shown)
            return shownConversation
        }
        set { observation.withMutation(of: self, keyPath: \.shown) { shownConversation = newValue } }
    }
    private var shownConversation: ConversationID?
    private let observation = ObservationRegistrar()
    /// The New Message page (Messages' New Message: a page, not a sheet).
    /// Kept while hidden when the person typed something, with its row in the list.
    private(set) var newMessage: HomeNewMessageView?
    /// The New Message page is the one on screen. Observed: each show and hide of the page goes through
    /// ``composing(_:)``.
    var isComposingNewMessage: Bool {
        observation.access(self, keyPath: \.isComposingNewMessage)
        return newMessage.map { !$0.isHidden } ?? false
    }
    /// The conversation the person sees: none on New Message (the list selects its row), else ``shown``.
    var displayedConversation: ConversationID? { isComposingNewMessage ? nil : shown }
    /// A conversation the person started that the inbox does not list yet: opened (with the
    /// keyboard in its box) when it shows.
    private var opening: ConversationID?
    /// A page built again after a discard: where its list was, applied once the rows are in.
    var pendingListScroll: CGPoint?
    /// This page in the visibility tree: its view-only observations read only while it is on screen (p06 section C).
    let visibility = ViewVisibility("topHome")
    /// The page's observations (recipe R-obs). Service observations write the Home model, start reads or pick the
    /// shown conversation, which must happen while the page hides too.
    private typealias RowFacts = (landed: Bool, all: [InboxRow], archived: Set<String>, owned: [HomeInboxRequest.Response?])
    private var rowsObservation: ServiceObservation<RowFacts>?
    private var selectionObservation: ServiceObservation<(pending: ConversationID?, listed: [ConversationID])>?
    private var chiefObservation: ServiceObservation<ChiefKey>?
    private var accountObservation: ServiceObservation<String?>?
    /// View observations on ``visibility``.
    private var requestsObservation: VisibleObservation<Int>?
    private var unreadColorObservation: VisibleObservation<NSColor?>?
    /// What the rows observation last acted on (it acts on changes only).
    private var badgedChiefs: Set<String>?
    private var listedConversations: Set<ConversationID> = []
    private var picturedRows: [HomeInboxRequest.Response?]?
    private var picturedChiefs: Set<String>?
    /// The preferred Chief and the Engine row's choice the Chief observation last acted on.
    private var lastChiefKey: ChiefKey?
    /// The conversation the page opened by itself, which a later Chief replaces (``followUp``).
    /// What the person picked is never this, so it is never taken off them: ``show(_:)`` clears it
    /// and only the two paths that open one themselves set it again.
    private(set) var followedChief: String?
    /// A conversation shown before the page had a window: the keyboard goes to it when the page gets one.
    private var focusesOnWindow = false
    /// False in the turn that builds the page: the observations' first applies fill the list but pick no conversation,
    /// so a rebuilt page's record (`restoreViewState`, later in that turn) shows its own conversation and nothing
    /// builds a transcript for the default one first. The page's first posted task picks one if none was restored.
    private var picksConversation = false

    init(services: AppServices, windowKey: @escaping () -> String) {
        self.services = services
        sidebar = services.home.makeSidebarSource()
        split = HomeSidebarSplitView(sidebar: list, content: transcriptColumn, mainWork: services.mainWork, caches: services.home.labCaches, page: visibility.node)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.topPage.home")
        split.windowKey = windowKey
        split.frame = bounds
        split.autoresizingMask = [.width, .height]
        addSubview(split)
        wireList(services)
        observe(services.home, auth: services.cloud.auth, on: services.mainWork)
        services.mainWork.post(.visible, owner: "TopHomePage.firstConversation") { [weak self, home = services.home] in
            guard let self else { return }
            picksConversation = true
            showPendingSelection(home)
            showDefaultConversation(home)
        }
        // At launch Home starts right after the first frame (its list shows the last launch's until then),
        // and the team and Chiefs read, a Cloud read, waits for that frame too.
        services.home.launchFeeds?.need()
        // task-owner: BackgroundWork (quit skips it); one read of the team and Chiefs, awaited off main (recipe R-hop)
        services.work.task(.userVisible) { [feeds = services.home.launchFeeds, directory = services.home.directory] in
            await feeds?.afterFirstFrame()
            await directory.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // cx-t7hu: not an isolated deinit (its hop traps inside an action's task-local scope); each observation stops itself.
    nonisolated deinit {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
        // A conversation shown before the page had a window takes the keyboard as `show` gives it in a window.
        guard focusesOnWindow, let window else { return }
        focusesOnWindow = false
        focusPrimaryInputUnasked(in: window)
    }

    var visibilityNode: VisibilityNode { visibility.node }

    override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
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
        let registry = services.registry, work = services.work
        // Mark as Read: the user's unread mark goes, and the read cursor moves to the newest message.
        list.onMarkRead = { id in
            sidebar.setMarkedUnread(false, id)
            guard let row = home.homeStore.rows.first(where: { $0.id == id }), row.unread > 0 else { return }
            let store = home.homeStore, seq = row.summary.lastSeq
            // task-owner: BackgroundWork; one op awaited off main (recipe R-hop), it ends with the owner's answer
            work.task(.userBlocking) { _ = try? await store.perform(.setReadCursor(conversation: id, seq: seq)) }
        }
        list.onMarkUnread = { id in if id != HomeSidebarView.draftRowID { sidebar.setMarkedUnread(true, id) } }
        // Conversation Info (sharing a Cloud Chief), Usage…, Archive Chief and Delete Chief… on a Chief's row; Hide or Show Alerts on a DM or group's row, and for a group
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
        // Search: teammates with no DM yet, under the conversations; choosing one starts the DM.
        list.teammates = { [weak sidebar] query in
            guard let sidebar else { return [] }
            return HomeSidebarModel(rows: home.homeStore.rows, pins: sidebar.pins, me: home.homeStore.me?.id, query: query,
                                    contacts: home.contacts()).people
        }
        list.onStartTeammate = { [weak self] person in
            // Awaited off main; the opening is the rest of the person's click: one userBlocking task (recipe R-hop).
            let opened: @MainActor @Sendable (ConversationID) -> Void = { [weak self] id in self?.openWhenListed(id) }
            let end = registry.completion(on: services.mainWork)
            end.start {
                guard case .opened(let id) = await home.startConversation([.contact(person)], title: "") else { return }
                end.post(owner: "TopHomePage.startTeammate", answering: true) { opened(id) }
            }
        }
        list.onNewMessage = { [weak self] in self?.presentNewMessage() }
        list.onOpenRequests = { [weak self] in self?.presentRequests() }
        list.composeMenu = { [weak services] in services.map { HomePageMenus.backgroundMenu(registry: $0.registry) } }
    }

    /// Follows the inbox rows and the conversation an action asked to show once it is listed (recipe R-obs).
    private func observe(_ home: HomeService, auth: CloudAuth, on work: MainWorkScheduler) {
        let store = home.homeStore, sidebar = sidebar, listLaunch = home.listLaunch
        rowsObservation = ServiceObservation(.visible, owner: "TopHomePage.rows", on: work) { () -> RowFacts in
            // Read for their changes: each redraws the list. A Chief's pet character is its avatar when it has none of
            // its own, the team is read after the page opens (its teammates are rows once it lands), and a rename of a
            // Chief redraws its tile.
            _ = (sidebar.query, sidebar.pins, sidebar.unreadMarks, home.chiefFaces, home.directory.chiefHarnesses, home.chiefRoster,
                 home.services?.settings?.snapshot.homeChiefPetMascot, home.directory.teamMembers, home.chiefNames)
            return (landed: listLaunch.isLanded, all: store.rows, archived: home.directory.archivedChiefs, owned: sidebar.ownerRows)
        } apply: { [weak self] facts in
            self?.rowsChanged(facts, home: home)
        }
        // The chief placed on a paired server (G6) replaces the local chief while the page shows the local one.
        followedChief = Self.chief(home)
        lastChiefKey = Self.chiefKey(home)
        chiefObservation = ServiceObservation(.visible, owner: "TopHomePage.chief", on: work) { Self.chiefKey(home) } apply: { [weak self] key in
            self?.chiefChanged(key, home: home)
        }
        // Another account has its own pins.
        accountObservation = ServiceObservation(.visible, owner: "TopHomePage.account", on: work) { auth.user?.id } apply: { _ in
            sidebar.reloadPins()
        }
        requestsObservation = VisibleObservation(visibility.node, owner: "TopHomePage.requests", on: work) {
            home.requests.items.count
        } apply: { [weak self] count in
            self?.list.showRequests(count)
        }
        // The unread dot is the unread rings' color (`notifications.attention.color`, nil: the notification blue).
        unreadColorObservation = VisibleObservation(visibility.node, owner: "TopHomePage.unreadColor", on: work) {
            home.services?.settings?.snapshot.attention.color?.nsColor
        } apply: { [weak self] color in
            self?.list.unreadDotColor = color
        }
        selectionObservation = ServiceObservation(.visible, owner: "TopHomePage.selection", on: work) {
            () -> (pending: ConversationID?, listed: [ConversationID]) in (pending: home.pendingSelection, listed: store.rows.map(\.id))
        } apply: { [weak self] _ in
            self?.showPendingSelection(home)
        }
    }

    /// Shows the conversation an action asked for once the inbox lists it (with the keyboard when the person started it).
    private func showPendingSelection(_ home: HomeService) {
        guard picksConversation, let id = home.pendingSelection, home.homeStore.rows.contains(where: { $0.id == id }) else { return }
        home.pendingSelection = nil
        show(id)
        if opening == id {
            opening = nil
            host?.takeKeyboardOnOpen()
        }
    }

    /// With nothing shown (and no New Message page), shows the Chief conversation, else the newest one.
    private func showDefaultConversation(_ home: HomeService) {
        guard picksConversation, shown == nil, !isComposingNewMessage, let first = Self.defaultConversation(rows: rows, home: home) else { return }
        show(first)
        // The page opened it, not the person, so a Chief that arrives later replaces it.
        followedChief = first.rawValue
    }

    /// The inbox rows changed: the Chiefs' engines and pictures are read again when their Chiefs or the owner's rows
    /// changed, the requests when a conversation came or went, and the list redraws.
    private func rowsChanged(_ facts: RowFacts, home: HomeService) {
        // Until the last launch's list is read the page is the theme background; then the seeded list shows in one frame.
        if split.isHidden == facts.landed { split.isHidden = !facts.landed }
        guard facts.landed else { return }
        let store = home.homeStore
        let chiefs = Set(facts.all.flatMap { $0.summary.participants.filter(\.isChief).map(\.id.rawValue) })
        if chiefs != badgedChiefs {
            badgedChiefs = chiefs
            home.refreshChiefHarnesses()
        }
        // A chief-changed event (a picture set by a tool or the CLI) reads the owner's rows again, and the pictures with them.
        if facts.owned != picturedRows || chiefs != picturedChiefs {
            picturedRows = facts.owned
            picturedChiefs = chiefs
            home.refreshChiefAvatars()
        }
        rows = Self.visible(facts.all, archivedChiefs: facts.archived, me: store.me?.id)
        // A conversation came or went (a lease arrived, a request was accepted): requests may have changed.
        let listed = Set(facts.all.map(\.id))
        if listed != listedConversations {
            listedConversations = listed
            home.requests.refresh()
        }
        list.update(sidebar.model())
        applyPendingListScroll()
        showDefaultConversation(home)
        // The cache's conversation of a Chief home made again (cx-ebm.55).
        if shownIsGone(store), let chief = Self.chief(home) { replaceGone(with: ConversationID(chief), store: store) }
    }

    /// The preferred Chief or the Engine row's choice changed: a gone conversation gives way to the
    /// Chief, and what the page opened by itself follows the new Chief (``followUp``).
    private func chiefChanged(_ key: ChiefKey, home: HomeService) {
        guard key != lastChiefKey else { return }
        lastChiefKey = key
        if let chief = key.chief, shownIsGone(home.homeStore) {
            replaceGone(with: ConversationID(chief), store: home.homeStore)
            followedChief = chief
            return
        }
        let next = Self.followUp(chief: key.chief, shown: shown, followed: followedChief,
                                 composing: isComposingNewMessage, rows: rows, home: home)
        // After the open, which clears it: every other ``show(_:)`` is the person's.
        if let open = next.open { show(open) }
        followedChief = next.followed
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
        if let window {
            focusPrimaryInputUnasked(in: window)
        } else {
            focusesOnWindow = true
        }
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

    /// A conversation nobody opened is shown (the default or the Chief's one, one shown before the page had a
    /// window): Home's primary input takes the keyboard only while it is free for this page, now and when the
    /// message box is installed (`NSWindow.keyboardIsFree(for:)`). In a pane that is the focus model's answer, so
    /// a browser page focused beside Home keeps the keys (QA chrome-parity-v2-2-2 bug 1).
    private func focusPrimaryInputUnasked(in window: NSWindow) {
        if isComposingNewMessage {
            if let target = newMessage?.focusTarget, window.keyboardIsFree(for: self) { window.makeFirstResponder(target) }
            return
        }
        host?.takeKeyboardOnOpen { [weak self] in
            guard let self, let window = self.window else { return false }
            return window.keyboardIsFree(for: self)
        }
    }

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
    /// the person left it. `focus` false leaves the keyboard where it is (a discarded page made again).
    func presentNewMessage(focus: Bool = true) {
        guard let services else { return }
        let page = newMessage ?? makeNewMessage(services)
        if page.superview == nil {
            page.frame = transcriptColumn.bounds
            page.autoresizingMask = [.width, .height]
            transcriptColumn.addSubview(page)
        }
        composing { page.isHidden = false }
        host?.isHidden = true
        split.composing = true
        list.setDraftRow(HomeNewMessageDraft.rowTitle)
        list.select(HomeSidebarView.draftRowID)
        page.needsLayout = true // invalidate: the page shows now; it lays out at the column's size before it takes focus.
        // sync-layout: the To: field takes focus below, at its frame in the shown page.
        page.layoutSubtreeIfNeeded()
        if focus { window?.makeFirstResponder(page.focusTarget) }
    }

    private func makeNewMessage(_ services: AppServices) -> HomeNewMessageView {
        let page = HomeNewMessageView(services: services)
        // The first send made the conversation: the draft ends and the page shows it.
        let mainWork = services.mainWork
        page.onSent = { [weak self] id in
            // Out of the draft store's send before the page goes: the rest of the person's send, one userBlocking task.
            mainWork.post(.userBlocking, owner: "TopHomePage.newMessageSent") { [weak self] in
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
            composing { page.isHidden = true }
            host?.isHidden = false
            split.composing = false
        }
        return true
    }

    /// Drops the New Message draft, its page and its row.
    private func endNewMessage() {
        guard let page = newMessage else { return }
        composing { newMessage = nil }
        page.stop()
        page.removeFromSuperview()
        host?.isHidden = false
        split.composing = false
        list.setDraftRow(nil)
    }

    /// Shows or hides the New Message page: readers of ``isComposingNewMessage`` hear it.
    private func composing(_ change: () -> Void) {
        observation.withMutation(of: self, keyPath: \.isComposingNewMessage, change)
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
}

extension TopHomePageView: Observable {}
