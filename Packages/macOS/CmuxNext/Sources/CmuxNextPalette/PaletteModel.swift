public import CmuxNextActions
public import Foundation
public import Observation

/// The palette's view model over the scope state machine.
///
/// Navigation (the stack of scopes, the query per level, the selection and
/// its memory, which batch is current) belongs to `PaletteNavReducer`
/// (plans/cmux-next/palette-scopes.md section 4); this model runs its
/// effects: it keeps one `PageState` per level (providers, search index,
/// cached rows), searches, runs commands, and mirrors the top level into
/// observable properties for the views. Non-empty queries are ranked off
/// the main actor by `PaletteSearcher`; results carry the level's
/// generation and the reducer drops stale ones.
@Observable
public final class PaletteModel {
    // MARK: Observable page state

    /// The search text (or the entry text on a text page).
    public var query: String = "" {
        didSet {
            guard query != oldValue, !isMirroring else { return }
            notice = nil
            selectsQuery = false
            send(.setQuery(query))
        }
    }

    public internal(set) var sections: [PaletteResultSection] = []
    /// The top level's selection (owned by the reducer).
    public internal(set) var selectedRowID: String? {
        didSet { if selectedRowID != oldValue { reportHighlight() } }
    }
    public internal(set) var hoveredRowID: String? {
        didSet { if hoveredRowID != oldValue { reportHighlight() } }
    }
    public internal(set) var actionsMenu: PaletteActionsMenuState?
    /// The inline shortcut recorder (Cmd-K on an action), when open.
    public internal(set) var shortcutRecorder: PaletteShortcutRecorderState?
    public internal(set) var pageTitle: String = ""
    public internal(set) var placeholder: String = ""
    public internal(set) var pageSymbol: String = "command"
    /// The scope of every level above the root, root side first: the chips.
    public internal(set) var scopeChips: [PaletteScopeChip] = []
    /// The scope the query names as a keyword: Tab enters it.
    public internal(set) var keywordHint: PaletteScopeChip?
    public internal(set) var isTextInput = false
    /// The text step opened on its initial text (a rename's current name):
    /// the field selects it, so typing replaces it and the arrow keys edit it.
    public internal(set) var selectsQuery = false
    /// Why the last command could not run, shown as its row's subtitle
    /// until the query or the page changes (never a beep).
    public internal(set) var notice: PaletteNotice?
    public internal(set) var isLoading = false
    /// Increments when keyboard navigation moves the selection, so the view
    /// scrolls it into view (mouse hover never scrolls).
    public internal(set) var scrollRequest = 0
    /// Increments on every page change so the view refocuses the field.
    public internal(set) var pageToken = 0
    /// Increments whenever `sections` is replaced, so list views reload once.
    public internal(set) var resultsVersion = 0

    // MARK: Non-observable state

    /// Called when a command closes the palette. The controller hides the
    /// panel here; the command's handler runs right after.
    @ObservationIgnored public var onDismiss: (@MainActor () -> Void)?
    /// Runs a closing command's handler and returns the reason it refused,
    /// if any (the controller installs `ActionRegistry.reportingRefusal`).
    /// Nil runs handlers directly.
    @ObservationIgnored public var performer: (@MainActor (@MainActor () -> Void) -> String?)?
    /// A closing command refused: the controller shows the palette again on
    /// the same page with `notice`.
    @ObservationIgnored public var onRefusal: (@MainActor (String) -> Void)?
    /// Cmd-K on a row that runs a registry action: opens the shortcut
    /// recorder. Returns false when it cannot (then the Actions menu opens).
    @ObservationIgnored public var onEditShortcut: (@MainActor (ActionID) -> Bool)?
    /// Accessibility announcement of the scope now on top (the controller
    /// posts it).
    @ObservationIgnored public var onAnnounce: (@MainActor (String) -> Void)?
    /// The page of a graph scope (`.root`, `tabs`, an app scope), with the
    /// row it was entered from (drill). Nil means pages are only those the
    /// caller opens and pushes: the first page opened is the root.
    @ObservationIgnored public var scopePage: (@MainActor (PaletteScopeID, PaletteItem?) -> PalettePageSpec?)?
    /// The navigation rules: the scope graph and the entry gestures.
    @ObservationIgnored public var navigation = PaletteNavReducer(graph: .rootOnly)
    /// Tab on a row with commands drills into its Actions scope instead of
    /// opening the floating Actions menu (Debug Settings
    /// `palette.itemActions`).
    @ObservationIgnored public var itemActionsAsScope = false
    /// How the chips look (Debug Settings `palette.scopeChip`).
    @ObservationIgnored public var chipStyle: PaletteScopeChipStyle = .token
    /// Which gestures enter scopes (Debug Settings `palette.scopeEntry`).
    @ObservationIgnored public var scopeEntry: PaletteScopeEntryStyle = .all
    /// Injected clock for frecency.
    @ObservationIgnored public var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored public internal(set) var frecency: FrecencyStore
    @ObservationIgnored let persistence: (any FrecencyPersisting)?
    @ObservationIgnored public internal(set) var nav = PaletteNavState()
    /// One page per level, by level id.
    @ObservationIgnored var pages: [Int: PageState] = [:]
    /// Pages a caller supplied for the next level of that scope.
    @ObservationIgnored var suppliedPages: [PaletteScopeID: PageState] = [:]
    @ObservationIgnored var current: PageState? { nav.top.flatMap { pages[$0.id] } }
    @ObservationIgnored var stack: [PageState] { nav.levels.compactMap { pages[$0.id] } }
    @ObservationIgnored let searcher = PaletteSearcher()
    @ObservationIgnored var searchGeneration = 0
    @ObservationIgnored var searchTask: Task<Void, Never>?
    /// Cmd-W pressed while a search was in flight; runs when it lands.
    @ObservationIgnored var pendingClose = false
    /// Which command a held or immediate `run` effect runs (Return or
    /// Cmd-Return).
    @ObservationIgnored var runCommand: PaletteKeyCommand = .submit
    @ObservationIgnored var queue: [PaletteNavEvent] = []
    @ObservationIgnored var isDraining = false
    @ObservationIgnored var isMirroring = false
    /// The level whose page chrome and rows are on screen.
    @ObservationIgnored var shownLevelID: Int?

    public init(frecency: FrecencyStore? = nil, persistence: (any FrecencyPersisting)? = nil) {
        self.persistence = persistence
        self.frecency = frecency ?? persistence?.load() ?? FrecencyStore()
    }

    // MARK: Derived

    /// Rows in display order.
    public var rows: [PaletteRow] { sections.flatMap(\.rows) }

    public var selectedItem: PaletteItem? {
        guard let selectedRowID else { return nil }
        for section in sections {
            if let row = section.rows.first(where: { $0.id == selectedRowID }) { return row.item }
        }
        return nil
    }

    /// Footer title for Return.
    public var primaryTitle: String? {
        guard let item = selectedItem, item.isEnabled else { return nil }
        return item.primary.title
    }

    public var depth: Int { nav.depth }

    /// "@ Tabs   # Workspaces   > Commands   ? All Scopes" for the footer of
    /// the empty root, when prefixes enter scopes.
    public var prefixHints: String? {
        guard scopeEntry.showsPrefixHints, navigation.config.prefixEntry, scopeChips.isEmpty, query.isEmpty else { return nil }
        let graph = navigation.graph
        let hints = graph.children(of: .root).compactMap { scope -> String? in
            guard let prefix = scope.prefix else { return nil }
            return scope.id == PaletteScopeCatalog.scopes ? "\(prefix) \(PaletteStrings.allScopes)" : "\(prefix) \(scope.title)"
        }
        return hints.isEmpty ? nil : hints.joined(separator: "   ")
    }

    /// Titles of the levels above the root (the chips).
    public var breadcrumbs: [String] { scopeChips.map(\.title) }

    /// Waits for the in-flight search, if any (tests, scripted checks).
    public func settle() async {
        while let task = searchTask {
            await task.value
            if searchTask == task { searchTask = nil }
        }
    }

    // MARK: Navigation

    /// Starts over at `page`, discarding the stack. Called on open. The
    /// full palette page (scope `.root`) opens alone; any other page opens
    /// above the root, so Backspace on its empty query shows the full
    /// palette. Without `scopePage` the page is the root itself.
    public func reset(to page: PalettePageSpec) {
        let state = PageState(kind: .list(page))
        if page.scope == .root || scopePage == nil {
            suppliedPages[.root] = state
            send(.open(scope: nil, query: page.initialQuery))
        } else {
            suppliedPages[page.scopeID] = state
            send(.open(scope: page.scopeID, query: page.initialQuery))
        }
    }

    /// Opens `scope` of the graph (shortcut, menu, CLI) above the root.
    public func open(scope: PaletteScopeID, query: String = "") {
        send(.open(scope: scope == .root ? nil : scope, query: query))
    }

    /// Starts over with the page an effect opens (argument collection from
    /// a menu or shortcut). A `.perform` effect runs immediately.
    public func reset(to effect: PaletteEffect, fallback: PalettePageSpec) {
        switch effect.resolved() {
        case .deferred: break
        case .push(let page): reset(to: page)
        case .textInput(let spec):
            let state = PageState(kind: .textInput(spec))
            let id = PaletteScopeID("input:\(spec.id)")
            if scopePage == nil {
                suppliedPages[.root] = state
                send(.open(scope: nil, query: spec.initialText))
            } else {
                suppliedPages[id] = state
                send(.open(scope: id, query: spec.initialText))
            }
        case .perform(let handler), .performKeepingOpen(let handler):
            reset(to: fallback)
            onDismiss?()
            perform(handler, rowID: nil, closing: true)
        }
    }

    /// Pushes `page` above the current level (a command's nested list).
    public func push(_ page: PalettePageSpec) {
        suppliedPages[page.scopeID] = PageState(kind: .list(page))
        send(.push(page.scopeID, row: selectedRowID, query: page.initialQuery))
    }

    func pushTextInput(_ spec: PaletteTextInputSpec) {
        let id = PaletteScopeID("input:\(spec.id)")
        suppliedPages[id] = PageState(kind: .textInput(spec))
        send(.push(id, row: selectedRowID, query: spec.initialText))
    }

    /// Pops one level. Returns false at the root.
    @discardableResult
    public func pop() -> Bool {
        let before = nav.depth
        send(.popTo(nav.depth - 2))
        return nav.depth < before
    }

    /// Pops to level `index` (a click on a chip; 0 is the root).
    public func pop(to index: Int) {
        send(.popTo(index))
    }

    /// Reloads every provider of the current page (after a keep-open command
    /// or when the App's data changed). The selection stays on its row.
    public func reload() {
        guard let current else { return }
        load(current)
        send(.refresh)
    }

    // MARK: Running commands

    /// Records a use of `key` (an item's `frecencyKey`) from outside the
    /// palette, so actions run by shortcut or menu also rank higher here.
    public func recordUse(_ key: String) {
        frecency.record(key, at: now())
        persistence?.save(frecency)
    }

    /// Runs `command` for `item`, recording usage.
    public func run(_ command: PaletteCommand, of item: PaletteItem) {
        guard item.isEnabled else { return }
        if item.enters != nil, command.id == item.primary.id {
            // A scope row: the reducer enters the scope.
            send(.activate(item.id))
            return
        }
        if let key = item.frecencyKey {
            frecency.record(key, at: now())
            persistence?.save(frecency)
        }
        switch command.effect.resolved() {
        case .deferred:
            break
        case .perform(let handler):
            current?.committed = true
            onDismiss?()
            perform(handler, rowID: item.id, closing: true)
        case .performKeepingOpen(let handler):
            perform(handler, rowID: item.id, closing: false)
            reload()
        case .push(let page):
            push(page)
        case .textInput(let spec):
            pushTextInput(spec)
        }
    }

    /// Runs a row's close command without closing the palette. Returns
    /// false when it refused (its reason becomes the row's notice).
    func performClose(_ command: PaletteCommand, rowID: String) -> Bool {
        let handler: @MainActor () -> Void
        switch command.effect.resolved() {
        case .perform(let run), .performKeepingOpen(let run): handler = run
        case .push, .textInput, .deferred: return false
        }
        guard let performer, let reason = performer(handler) else {
            if performer == nil { handler() }
            return true
        }
        notice = PaletteNotice(rowID: rowID, text: reason)
        publish(sections, resetSelection: false)
        return false
    }

    /// Whether the shown page takes Cmd-W for its rows
    /// (`PalettePageSpec.ownsCloseKey`).
    public var currentPageOwnsCloseKey: Bool {
        guard let current, case .list(let page) = current.kind else { return false }
        return page.ownsCloseKey
    }

    /// The id of the shown page (`PalettePageSpec.id`); nil on a text page.
    public var currentPageID: String? {
        guard let current, case .list(let page) = current.kind else { return nil }
        return page.id
    }

    /// Runs `handler`; a refusal becomes the notice on `rowID` (the page's
    /// first row when nil) and, for a closing command, reopens the palette
    /// on the same page. The handler targets what the palette captured on
    /// open (`PaletteArgumentFlow`), so reopening changes nothing it acts on.
    private func perform(_ handler: @MainActor () -> Void, rowID: String?, closing: Bool) {
        guard let performer else { return handler() }
        guard let reason = performer(handler) else { return }
        notice = PaletteNotice(rowID: rowID ?? rows.first?.id ?? "", text: reason)
        publish(sections, resetSelection: false)
        if closing { onRefusal?(reason) }
    }
}

extension PaletteModel {
    /// Shows `text` on the row of action `id` (the selected row when it is
    /// that action's), like a refusal notice.
    func showNotice(_ text: String, on id: ActionID) {
        let row = selectedItem?.actionID == id ? selectedRowID : rows.first { $0.item.actionID == id }?.id
        notice = PaletteNotice(rowID: row ?? rows.first?.id ?? "", text: text)
        publish(sections, resetSelection: false)
    }
}

/// A command's refusal, shown on its row.
public struct PaletteNotice: Equatable, Sendable {
    public let rowID: String
    public let text: String
}

/// One chip: a level above the root.
public struct PaletteScopeChip: Equatable, Sendable {
    public let levelIndex: Int
    public let scope: PaletteScopeID
    public let title: String
    public let symbol: String
}
