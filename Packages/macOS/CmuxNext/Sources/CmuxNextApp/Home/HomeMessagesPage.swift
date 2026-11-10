import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHomeModel
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups

/// The docked Home's Messages view: the React page `cmux.home-messages` (the conversation list,
/// the transcript and composer, the sheets and the in-chat cards), one page kept and reused for
/// the dock tab's life. The app tells it what only the app knows: the window's traffic lights over
/// its top-left (``HomeMessagesPageRoute/setWindowControls(_:)``), and what the palette, the menus
/// and the CLI ask of the shown Home (open a conversation, present a sheet, step the list), through
/// the host-to-page calls the page serves (`home.messages.*`, `home.moveConversation`,
/// `home.currentSelection`). A strip over its top edge drags the window, as the native list's
/// header did.
///
/// It names its page to the focus model (``PageWebViewContainer``), so a Home pane tab or classic
/// Home's top page that gets the keyboard gives it to Chromium (`InternalPageView.focusTarget`), and
/// the page hands it on to its message box (pageCommands.ts `followPageFocus`).
@MainActor
final class HomeMessagesPage: NSView, PageWebViewContainer {
    /// The sheets the page draws (sheets/), by the name `home.messages.present` takes.
    enum Sheet: String {
        case newMessage, requests, groupInfo, newChief, invite, teamInvite, closeNewMessage
    }

    let page: PageWebView
    let route: HomeMessagesPageRoute
    let host: HomeMessagesHostProvider
    private let dragStrip = HomeWindowDragStrip()
    private weak var services: AppServices?
    /// Follows `HomeService.pendingSelection` (a conversation a sheet, the CLI or a run started), the
    /// preferred Chief and the unread colour.
    private var watches: [Task<Void, Never>] = []
    /// The Chief conversation the page opened by itself (a later Chief replaces it); nil once the person picked.
    private var followed: String?
    /// The list's pins and hidden conversations (``HomeListPage``): a source over the owner's stores.
    let sidebar: HomeSidebarSource
    /// The header band the traffic lights may lie over (the list's `HEADER.band`, list/layout.ts).
    static let band: CGFloat = 52
    /// How long a host-to-page call waits for the page (its first load, a reconnect) before it gives up.
    static let answerDeadline: Duration = .seconds(5)

    init(services: AppServices, page: PageWebView, route: HomeMessagesPageRoute, host: HomeMessagesHostProvider) {
        self.services = services
        self.page = page
        self.route = route
        self.host = host
        sidebar = services.home.makeSidebarSource()
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.homeMessages")
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
        addSubview(dragStrip)
        watch(services.home)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The Messages page for the docked Home (`dock`), classic Home's top page or a Home pane tab
    /// (no dock: no view switch); nil when the page bundle is missing. `widthKey`: the list's width is kept per key.
    static func make(services: AppServices, dock: HomeDockView? = nil, widthKey: String = HomeDockTab.widthKey) -> HomeMessagesPage? {
        guard let made = PageFactory(services: services).homeMessagesWebPage(dock: dock, widthKey: widthKey) else { return nil }
        // A web link the person clicks opens on the Home workspace's right side, as in Channels.
        made.page.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
        return HomeMessagesPage(services: services, page: made.page, route: made.route, host: made.host)
    }

    nonisolated deinit {
        for watch in watches { watch.cancel() }
    }

    /// The conversation the page shows, as it last said (`cmux.home.messages.selected`).
    var shown: ConversationID? { host.shown }

    /// The page the focus model gives the keyboard to (``PageWebView/shown(in:)``).
    var shownPageView: PageWebView? { page }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        dragStrip.frame = dragStrip.frame(in: bounds)
        updateWindowControls()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowControls()
    }

    /// The window's traffic lights over the page's top band, in its points from its top-left; nil
    /// when none lie there (the window's sidebar beside the page, full screen, no window).
    func updateWindowControls() {
        route.setWindowControls(HomeWindowDragStrip.windowControls(over: self, band: Self.band))
    }

    private func watch(_ home: HomeService) {
        let store = home.homeStore
        watches.append(HomeMessagesSelectionWatch(pending: { home.pendingSelection }, spend: { home.pendingSelection = nil }, rows: { store.rows.map(\.id) })
            .follow { [weak self] id in self?.show(HomeDockSelection(conversation: id.rawValue), focus: true) })
        // The page opens the preferred Chief by itself while nothing of the person's shows, on its
        // first load as later (HomeDefaultConversation.afterShown), and follows it as it changes
        // (HomeDefaultConversation.followUp); what the person opened, and New Message, stay.
        followed = nil
        host.onShown = { [weak self] id, composing in
            guard let self else { return }
            let next = HomeDefaultConversation.afterShown(id, composing: composing, followed: followed, rows: visibleRows(home), home: home)
            followed = next.followed
            if let open = next.open { show(HomeDockSelection(conversation: open.rawValue)) }
        }
        // Nothing to open yet when the page first said it shows nothing (the store's rows not read
        // yet): the first listed default opens once there is one.
        // task-owner: lives as long as this view (cancelled in deinit); event-driven (Observation)
        watches.append(Task { [weak self] in
            for await _ in ObservationStream({ store.rows.map(\.id) }) {
                guard let self, host.page.reported, host.shown == nil, !host.page.composing,
                      let first = HomeDefaultConversation.defaultConversation(rows: visibleRows(home), home: home) else { continue }
                followed = first.rawValue
                show(HomeDockSelection(conversation: first.rawValue))
            }
        })
        // The conversations deleted from the list: any page's Delete or Show Hidden Conversations
        // (``HomeService/hiddenRevision``) reads this page's set again, and the page hears each change.
        host.hidden.hidden = { [weak self] in self?.sidebar.hidden ?? [:] }
        host.hidden.archived = { HomeArchivedChiefs(home.directory.archivedChiefs, me: home.homeStore.me?.id).hiddenConversations(store.rows) }
        let source = sidebar
        host.list.sources = HomeMessagesListSources(model: { [weak source] in source?.model() }, contacts: { [weak home] in home?.contacts() ?? [] },
                                                    rows: { store.rows }, chiefsChanged: { [weak home] in home?.refreshChiefHarnesses(); home?.refreshChiefAvatars() },
                                                    listedChanged: { [weak home] in home?.requests.refresh() })
        host.list.onDragBand = { [weak self] in self?.dragStrip.setBand($0, controls: $1) }
        // task-owner: lives as long as this view (cancelled in deinit); event-driven (Observation)
        watches.append(Task { [weak self] in
            var last = home.hiddenRevision
            for await revision in ObservationStream({ home.hiddenRevision }) {
                guard self != nil, revision != last else { continue }
                last = revision
                source.reloadPins()
            }
        })
        // task-owner: lives as long as this view (cancelled in deinit); event-driven (Observation)
        watches.append(Task { [weak self] in
            for await _ in ObservationStream({ (source.hidden, home.directory.archivedChiefs, store.rows.map(\.id)) }) { self?.host.hidden.publish() }
        })
        // task-owner: lives as long as this view (cancelled in deinit); event-driven (Observation)
        watches.append(Task { [weak self] in
            var last = HomeDefaultConversation.chiefKey(home)
            for await key in ObservationStream({ HomeDefaultConversation.chiefKey(home) }) {
                guard let self, key != last else { continue }
                last = key
                let next = HomeDefaultConversation.followUp(chief: key.chief, shown: shown, followed: followed, composing: host.page.composing,
                                                            rows: visibleRows(home), home: home)
                followed = next.followed
                if let open = next.open { show(HomeDockSelection(conversation: open.rawValue)) }
            }
        })
        // task-owner: lives as long as this view (cancelled in deinit); event-driven (Observation)
        watches.append(Task { [weak self] in
            for await _ in ObservationStream({ home.services.settings?.snapshot.attention.color }) {
                self?.route.publishChrome()
            }
        })
    }

    /// The listed rows without archived Chiefs' (``HomeArchivedChiefs``).
    private func visibleRows(_ home: HomeService) -> [InboxRow] {
        HomeArchivedChiefs(home.directory.archivedChiefs, me: home.homeStore.me?.id).visible(home.homeStore.rows)
    }

    // MARK: Asking the page

    /// Calls the page op `op`, waiting for the page to load and answer (`within`, ``answerDeadline``); nil
    /// when it never answers (a closed page, an older bundle) or refuses. Every try carries one
    /// request id, so a try that timed out but ran is not run again (``HomePageAskAttempt``).
    @discardableResult
    func ask(_ op: String, _ params: [String: JSONValue] = [:], within: Duration = HomeMessagesPage.answerDeadline) async -> JSONValue? {
        let (router, clock, call) = (page.router, ContinuousClock(), JSONValue.object(params.merging(["request": .string(UUID().uuidString)]) { $1 }))
        let end = clock.now.advanced(by: within)
        var backoff = Backoff(initial: .milliseconds(100), maximum: .seconds(1))
        // A page still loading (or reconnecting) has no handler yet: ask again, spaced by a backoff,
        // until it answers. Stops at the first answer or refusal, at the deadline, or when the task ends.
        while clock.now < end, !Task.isCancelled {
            switch await PageAnswerDeadline(.seconds(1)).answer({ () async -> HomePageAskAttempt in
                do { return .answered(try await router.callPage(op, params: call)) } catch { return HomePageAskAttempt(error) }
            }) {
            case .answered(let answer)?: return answer
            case .refused?: return nil
            case .notReady?, nil: break
            }
            // concurrency-allow: Backoff.wait suspends the task (no thread blocks); it spaces the retries of a call the page could not take yet
            do { try await backoff.wait(owner: "home.messages.ask") } catch { return nil }
        }
        return nil
    }

    /// Opens a conversation (and its message), as a click on its row; `focus` gives its message box the keyboard.
    func show(_ selection: HomeDockSelection, focus: Bool = false, draft: String? = nil) {
        var params: [String: JSONValue] = ["conversation": .string(selection.conversation)]
        if let message = selection.message { params["message"] = .string(message) }
        if let draft { params["draft"] = .string(draft) }
        // task-owner: one page call; ends with its answer (bounded by answerDeadline)
        // main-hop-allow: already on main (a menu, palette or CLI action); the task only awaits the page's answer
        Task { @MainActor [weak self] in
            await self?.ask("home.messages.show", params)
            if focus { self?.focusPrimaryInput() }
        }
    }

    /// The person opened `id`: shown, and its message box takes the keyboard.
    func open(_ id: ConversationID) { show(HomeDockSelection(conversation: id.rawValue), focus: true) }

    /// Presents one of the page's sheets (New Message, Requests, Group Info, New Chief, Invite).
    func present(_ sheet: Sheet, conversation: ConversationID? = nil, prefill: String? = nil) {
        var params: [String: JSONValue] = ["sheet": .string(sheet.rawValue)]
        if let conversation { params["conversation"] = .string(conversation.rawValue) }
        if let prefill { params["prefill"] = .string(prefill) }
        // task-owner: one page call; ends with its answer (bounded by answerDeadline)
        // main-hop-allow: already on main (a menu, palette or CLI action); the task only awaits the page's answer
        Task { @MainActor [weak self] in
            let answer = await self?.ask("home.messages.present", params)
            if let refusal = HomeGroupOutcome.presentRefusal(sheet: sheet.rawValue, answer: answer) { self?.services?.registry.refuse(refusal) }
        }
    }

    /// The previous or next conversation in the list (wrapping), opened.
    func move(by offset: Int) async -> Bool {
        await ask("home.moveConversation", ["delta": .number(Double(offset))])?.objectValue?["moved"]?.boolValue == true
    }

    /// The `number`th conversation of the list (9: the last), opened.
    func select(number: Int) async -> Bool {
        await ask("home.messages.selectNumber", ["number": .number(Double(number))])?.objectValue?["selected"]?.boolValue == true
    }

    /// The page's selection (`home.currentSelection`) for the dock's view switch.
    func selection() async -> HomeDockSelection? {
        guard let fields = await ask("home.currentSelection")?.objectValue, let conversation = fields["conversation"]?.stringValue,
              HomeDockSelection.isLinkID(conversation) else { return nil }
        let message = fields["message"]?.stringValue.flatMap { HomeDockSelection.isLinkID($0) ? $0 : nil }
        return HomeDockSelection(conversation: conversation, message: message)
    }

    /// The page's primary input (the message box, or To: on New Message) takes the keyboard.
    func focusPrimaryInput() {
        let focus = { [weak self] in
            guard let self else { return }
            page.focusPage()
            // task-owner: one page call; ends with its answer (bounded by answerDeadline)
            // main-hop-allow: already on main (a focus request); the task only awaits the page's answer
            Task { @MainActor [weak self] in await self?.ask("home.messages.focusComposer") }
        }
        if page.window != nil { focus() } else { page.whenPainted(focus) }
    }

    /// The dock tab closed: the page's document ends.
    func close() {
        for watch in watches { watch.cancel() }
        watches = []
        page.close()
    }
}

/// The list actions (Pin, Delete from List) change the owner's stores; the page's list hears pins
/// from them and the deleted conversations from this page's source (the `hidden` stream).
extension HomeMessagesPage: HomeListPage {
    /// A pin or delete changed (maybe through another source over the same account): read them again.
    func listPinsChanged() {
        sidebar.reloadPins()
    }

    /// The page left `id` while it showed it (Delete Conversation from List): its neighbor shows, else the default.
    func conversationLeft(_ id: ConversationID, next: ConversationID?) {
        guard shown == id, let home = services?.home,
              let replacement = HomeDefaultConversation.replacement(leaving: id, next: next, rows: visibleRows(home), home: home) else { return }
        show(HomeDockSelection(conversation: replacement.rawValue))
    }
}

/// The app's files reach the page's composer through ``HomeComposerIntake``.
extension HomeMessagesPage: HomeComposerPage {
    var intake: HomeMessagesIntake { host.intake }
}
