public import AppKit
public import Observation

/// The native New Tab page's state: the typed text, the selected kind and the dropdown's
/// highlighted row (``NativeNewTabView`` draws it).
///
/// The rows are computed from the page's snapshot on each change, never stored, so they
/// cannot go stale. Construct one per page with the page and an action bundle:
///
/// ```swift
/// let model = NativeNewTabModel(page: page, actions: NativeNewTabActions(submit: { text, kind, search, event in … }))
/// ```
@MainActor @Observable
public final class NativeNewTabModel {
    /// The page's context: its omnibar lists (open tabs, workspaces, pages, palette actions).
    public private(set) var page: AgentPaneNewTab
    /// The field's text.
    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            highlighted = nil
            if !text.isEmpty { used() }
        }
    }
    /// The Terminal | Browser | Agent switch.
    public var kind: AgentPaneTabKind
    /// The highlighted row's index in ``rows``; nil is the first row (Return's default).
    public var highlighted: Int?
    /// The device's newest chats (the host's Chats feed): the rows search their titles.
    public var chats: [AgentPaneDeviceChat] = []
    @ObservationIgnored private var actions: NativeNewTabActions
    @ObservationIgnored private let ranker: NativeNewTabRanker
    /// Asks for the palette's actions once, at the first keystroke or ``loadPaletteActions()``; they come later
    /// (the host reads them as budgeted background work, ``AgentPaneNewTabActions``), never in the keystroke's turn.
    /// `(wanted, deliver)`: `wanted` says whether the page still waits (false once it is gone), asked when the read starts.
    public typealias PaletteActionsRequest = @MainActor (_ wanted: @escaping @MainActor () -> Bool,
                                                         _ deliver: @escaping @MainActor ([AgentPaneOmnibar.Action]) -> Void) -> Void
    @ObservationIgnored private var paletteActions: PaletteActionsRequest?
    /// Asks for the palette's actions again, once, at the person's first use of the page (a typed letter or a run
    /// of a row): the host reads them again when the page showed with a list that was read before it (the kept
    /// list, ``AgentPaneNewTabActions/kept``), and does nothing when the page's own listing read its list.
    @ObservationIgnored private var paletteRefresh: PaletteActionsRequest?
    /// The host's favicon revision and a cheap context refresh. Both run only in the view's background observation task,
    /// never while the field ranks a keystroke.
    @ObservationIgnored var favicons: NativeNewTabFavicons?
    /// Which ask an answer belongs to: an adoption (a new tab's context) drops an earlier page's answer.
    @ObservationIgnored private var paletteAsk = 0

    /// Creates the model.
    /// - Parameters:
    ///   - page: The page's context, as the web page gets it.
    ///   - actions: What the page asks its host to do.
    ///   - ranker: Picks the dropdown's rows.
    ///   - paletteActions: Asks for the Commands palette's actions, when `page` was built without them so the
    ///     page shows first; nil when `page.omnibar.actions` already holds them.
    ///   - paletteRefresh: Asks for them again at the person's first use of the page; nil when no list is kept.
    ///   - chats: The device's newest chats (the host's Chats feed), for the chat rows.
    public init(page: AgentPaneNewTab, actions: NativeNewTabActions, ranker: NativeNewTabRanker = NativeNewTabRanker(),
                paletteActions: PaletteActionsRequest? = nil, paletteRefresh: PaletteActionsRequest? = nil,
                chats: [AgentPaneDeviceChat] = [], favicons: NativeNewTabFavicons? = nil) {
        self.page = page
        self.chats = chats
        self.kind = page.kind
        self.actions = actions
        self.ranker = ranker
        self.paletteActions = paletteActions
        self.paletteRefresh = paletteRefresh
        self.favicons = favicons
    }

    /// Asks for the dropdown's palette actions if they are not there yet (the host calls it on the frame after the
    /// page shows; the first keystroke calls it when that frame has not come). The rows take them when they come.
    public func loadPaletteActions() {
        guard let ask = paletteActions else { return }
        paletteActions = nil
        listPaletteActions(by: ask)
    }

    /// The person's first use of the page: the palette's actions are asked for again (``paletteRefresh``), in place
    /// of the show's ask when that was not made yet. The turn of the use only asks; the list comes in a later one.
    private func used() {
        guard let ask = paletteRefresh else { return loadPaletteActions() }
        (paletteRefresh, paletteActions) = (nil, nil)
        listPaletteActions(by: ask)
    }

    /// Asks `request` for the palette's actions and takes its answer when it comes (the host asks again so after a
    /// row's run that the palette refused). An equal list changes nothing. A list that differs changes the rows in
    /// one update, and the highlighted row stays the same row, by its id, while the new rows have it; a highlighted
    /// row that is gone gives Return back to the first row.
    public func listPaletteActions(by request: PaletteActionsRequest) {
        let asked = paletteAsk
        request({ [weak self] in self.map { asked == $0.paletteAsk } ?? false }, { [weak self] actions in
            guard let self, asked == paletteAsk, actions != page.omnibar.actions else { return }
            let row = highlighted == nil ? nil : selectedIndex.map { rows[$0].id }
            page.omnibar.actions = actions
            if let row { highlighted = rows.firstIndex { $0.id == row } }
        })
    }

    /// The dropdown's rows for the current text and kind.
    public var rows: [NativeNewTabRow] { ranker.rows(for: text, kind: kind, omnibar: page.omnibar, sources: sources) }

    /// The chats and the start folders and agents the rows draw from: the page's projects (this
    /// Mac's, most recent first), its last agent and home folder.
    var sources: NativeNewTabSources {
        NativeNewTabSources(chats: chats, folders: page.projects + page.omnibar.projects, defaultAgent: page.lastAgent ?? "claude",
                            home: page.home)
    }

    /// The row Return takes.
    public var selectedIndex: Int? {
        let count = rows.count
        guard count > 0 else { return nil }
        return min(highlighted ?? 0, count - 1)
    }

    /// Cmd-T adopted this prepared page (the New Tab spare): it takes the new tab's context and
    /// requests, starts empty, and lists the palette's actions from `paletteActions` when asked.
    /// - Parameters:
    ///   - page: The new tab's context, built without the palette's actions.
    ///   - actions: What the page asks its host to do, for the tab it now is.
    ///   - paletteActions: Asks for the Commands palette's actions, once (``loadPaletteActions()``).
    ///   - paletteRefresh: Asks for them again at the person's first use of the page; nil when no list is kept.
    public func adopt(page: AgentPaneNewTab, actions: NativeNewTabActions, paletteActions: PaletteActionsRequest?,
                      paletteRefresh: PaletteActionsRequest? = nil, chats: [AgentPaneDeviceChat] = []) {
        paletteAsk &+= 1
        self.page = page
        self.chats = chats
        self.actions = actions
        self.paletteActions = paletteActions
        self.paletteRefresh = paletteRefresh
        kind = page.kind
        text = ""
        highlighted = nil
    }

    /// The open tabs and workspaces changed while the page shows; the typed text stays.
    public func update(_ page: AgentPaneNewTab) { self.page = page }

    /// Replaces only the host's favicon-bearing snapshot after the favicon store changes. The host calls this from
    /// an observation task, so a missing icon can arrive later without making the input path wait.
    public func refreshFaviconPage() {
        guard let favicons else { return }
        let refreshed = favicons.page(page)
        guard refreshed.omnibar.tabs != page.omnibar.tabs || refreshed.omnibar.history != page.omnibar.history ||
                refreshed.omnibar.bookmarks != page.omnibar.bookmarks else { return }
        page = refreshed
    }

    /// Reads the host's revision inside an observation scope. It is deliberately separate from ``rows``.
    public func faviconRevisionTick() -> Int { favicons?.revision() ?? 0 }

    /// Down (`1`) or Up (`-1`): moves the highlight, wrapping at the ends.
    public func move(_ step: Int) {
        let count = rows.count
        guard count > 0 else { return }
        highlighted = ((selectedIndex ?? 0) + step + count) % count
    }

    /// Return: the highlighted row, or for an empty field the selected kind as it is (the open
    /// tabs listed under an empty field run only once Up or Down highlights one). `event`: the Return key press.
    public func commit(event: NSEvent? = nil) {
        if text.isEmpty, highlighted == nil { return actions.submit("", kind, false, event) }
        if let index = selectedIndex { return activate(rows[index], event: event) }
        actions.submit("", kind, false, event)
    }

    /// Runs `row`, as Return or a click on it does. Only a palette action's row is a first use that asks for the
    /// actions again (a run of another row opens something else, and a listing would run in that open's frames);
    /// the host runs an action only when the palette still lists it under the title the row shows. `event`: the key
    /// or click that ran it (``NativeNewTabActions/submit``), nil for an accessibility press.
    public func activate(_ row: NativeNewTabRow, event: NSEvent? = nil) {
        switch row {
        case .ask(let text): actions.submit(text, .agent, false, event)
        case .run(let text): actions.submit(text, .terminal, false, event)
        case .open(let text): actions.submit(text, .browser, false, event)
        case .tab(let tab): actions.jump(.tab, tab.id)
        case .workspace(let workspace): actions.jump(.workspace, workspace.id)
        case .page(let page): actions.submit(page.url, .browser, false, event)
        case .bookmark(let page): actions.submit(page.url, .browser, false, event)
        case .action(let action):
            used()
            actions.action(action.id, action.title)
        case .chat(let chat): actions.openChat(chat.key)
        case .start(let start): actions.start(start.harness, start.folder)
        }
    }
}
