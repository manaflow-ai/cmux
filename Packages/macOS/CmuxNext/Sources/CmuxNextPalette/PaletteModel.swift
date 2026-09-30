import CmuxNextActions
public import Foundation
public import Observation

/// The palette's navigation state machine and view model.
///
/// Holds a stack of pages (root list, nested lists, text entry). Each page
/// keeps its own query and selection so popping restores them. Views read
/// the observable properties; the panel controller feeds key commands.
/// Non-empty queries are ranked off the main actor by `PaletteSearcher`;
/// results carry a generation and stale ones are dropped.
@Observable
public final class PaletteModel {
    // MARK: Observable page state

    /// The search text (or the entry text on a text page).
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            current?.query = query
            refreshResults(resetSelection: true)
        }
    }

    public internal(set) var sections: [PaletteResultSection] = []
    public internal(set) var selectedRowID: String?
    public internal(set) var hoveredRowID: String?
    public internal(set) var actionsMenu: PaletteActionsMenuState?
    public private(set) var pageTitle: String = ""
    public private(set) var placeholder: String = ""
    public private(set) var pageSymbol: String = "command"
    /// Titles of the pages above the root, for the breadcrumb.
    public private(set) var breadcrumbs: [String] = []
    public private(set) var isTextInput = false
    public internal(set) var isLoading = false
    /// Increments when keyboard navigation moves the selection, so the view
    /// scrolls it into view (mouse hover never scrolls).
    public internal(set) var scrollRequest = 0
    /// Increments on every page change so the view refocuses the field.
    public private(set) var pageToken = 0
    /// Increments whenever `sections` is replaced, so list views reload once.
    public internal(set) var resultsVersion = 0

    // MARK: Non-observable state

    /// Called when a command closes the palette. The controller hides the
    /// panel here; the command's handler runs right after.
    @ObservationIgnored public var onDismiss: (@MainActor () -> Void)?
    /// Injected clock for frecency.
    @ObservationIgnored public var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored public internal(set) var frecency: FrecencyStore
    @ObservationIgnored let persistence: (any FrecencyPersisting)?
    @ObservationIgnored var stack: [PageState] = []
    @ObservationIgnored var current: PageState? { stack.last }
    @ObservationIgnored let searcher = PaletteSearcher()
    @ObservationIgnored var searchGeneration = 0
    @ObservationIgnored var searchTask: Task<Void, Never>?
    /// A Return pressed while a search was in flight; runs when it lands.
    @ObservationIgnored var pendingSubmit: PaletteKeyCommand?

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

    public var depth: Int { stack.count }

    /// Waits for the in-flight search, if any (tests, scripted checks).
    public func settle() async {
        while let task = searchTask {
            await task.value
            if searchTask == task { searchTask = nil }
        }
    }

    // MARK: Navigation

    /// Starts over at `page`, discarding the stack. Called on open.
    public func reset(to page: PalettePageSpec) {
        clearStack()
        push(page)
    }

    /// Starts over with the page an effect opens (argument collection from
    /// a menu or shortcut). A `.perform` effect runs immediately.
    public func reset(to effect: PaletteEffect, fallback: PalettePageSpec) {
        clearStack()
        switch effect.resolved() {
        case .deferred: break
        case .push(let page): push(page)
        case .textInput(let spec): pushTextInput(spec)
        case .perform(let handler), .performKeepingOpen(let handler):
            push(fallback)
            onDismiss?()
            handler()
        }
    }

    public func push(_ page: PalettePageSpec) {
        let state = PageState(kind: .list(page))
        stack.append(state)
        actionsMenu = nil
        load(state)
        activate(state, restoring: false)
    }

    func pushTextInput(_ spec: PaletteTextInputSpec) {
        let state = PageState(kind: .textInput(spec))
        state.query = spec.initialText
        stack.append(state)
        actionsMenu = nil
        activate(state, restoring: false)
    }

    /// Pops one page. Returns false at the root.
    @discardableResult
    public func pop() -> Bool {
        guard stack.count > 1 else { return false }
        stack.removeLast().cancel()
        actionsMenu = nil
        if let current { activate(current, restoring: true) }
        return true
    }

    /// Reloads every provider of the current page (after a keep-open command
    /// or when the App's data changed).
    public func reload() {
        guard let current else { return }
        load(current)
        refreshResults(resetSelection: false)
    }

    private func clearStack() {
        for state in stack { state.cancel() }
        stack = []
        actionsMenu = nil
        hoveredRowID = nil
        pendingSubmit = nil
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
        if let key = item.frecencyKey {
            frecency.record(key, at: now())
            persistence?.save(frecency)
        }
        switch command.effect.resolved() {
        case .deferred:
            break
        case .perform(let handler):
            onDismiss?()
            handler()
        case .performKeepingOpen(let handler):
            handler()
            reload()
        case .push(let page):
            push(page)
        case .textInput(let spec):
            pushTextInput(spec)
        }
    }

    private func activate(_ state: PageState, restoring: Bool) {
        switch state.kind {
        case .list(let page):
            pageTitle = page.title
            placeholder = page.placeholder
            pageSymbol = page.symbol
            isTextInput = false
        case .textInput(let spec):
            pageTitle = spec.title
            placeholder = spec.placeholder
            pageSymbol = spec.symbol
            isTextInput = true
        }
        breadcrumbs = stack.dropFirst().map(\.title)
        isLoading = !state.pendingProviders.isEmpty
        let savedSelection = state.selectedRowID
        if restoring, let cached = state.lastSections {
            // Show the page as it was while its search refreshes.
            publish(cached, resetSelection: false)
        }
        // Assigning the query refreshes through its didSet; otherwise refresh here.
        if query != state.query {
            query = state.query
        } else {
            refreshResults(resetSelection: true)
        }
        if restoring, let savedSelection {
            restoreSelection = savedSelection
            applyRestoredSelection()
        }
        pageToken += 1
    }

    /// Selection to restore after popping, applied once results land.
    @ObservationIgnored var restoreSelection: String?

    func applyRestoredSelection() {
        guard let saved = restoreSelection, rows.contains(where: { $0.id == saved }) else { return }
        restoreSelection = nil
        selectedRowID = saved
        current?.selectedRowID = saved
        scrollRequest += 1
    }
}
