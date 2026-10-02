public import CmuxNextActions
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
            notice = nil
            current?.query = query
            refreshResults(resetSelection: true)
        }
    }

    public internal(set) var sections: [PaletteResultSection] = []
    public internal(set) var selectedRowID: String? {
        didSet { if selectedRowID != oldValue { reportHighlight() } }
    }
    public internal(set) var hoveredRowID: String? {
        didSet { if hoveredRowID != oldValue { reportHighlight() } }
    }
    public internal(set) var actionsMenu: PaletteActionsMenuState?
    /// The inline shortcut recorder (Cmd-K on an action), when open.
    public internal(set) var shortcutRecorder: PaletteShortcutRecorderState?
    public private(set) var pageTitle: String = ""
    public private(set) var placeholder: String = ""
    public private(set) var pageSymbol: String = "command"
    /// Titles of the pages above the root, for the breadcrumb.
    public private(set) var breadcrumbs: [String] = []
    public private(set) var isTextInput = false
    /// Why the last command could not run, shown as its row's subtitle
    /// until the query or the page changes (never a beep).
    public internal(set) var notice: PaletteNotice?
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
            perform(handler, rowID: nil, closing: true)
        }
    }

    public func push(_ page: PalettePageSpec) {
        let state = PageState(kind: .list(page))
        state.query = page.initialQuery
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
        let removed = stack.removeLast()
        removed.cancel()
        leave(removed)
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
        for state in stack.reversed() {
            state.cancel()
            leave(state)
        }
        stack = []
        actionsMenu = nil
        shortcutRecorder = nil
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
    func performClose(_ command: PaletteCommand) -> Bool {
        let handler: @MainActor () -> Void
        switch command.effect.resolved() {
        case .perform(let run), .performKeepingOpen(let run): handler = run
        case .push, .textInput, .deferred: return false
        }
        guard let performer, let reason = performer(handler) else {
            if performer == nil { handler() }
            return true
        }
        notice = PaletteNotice(rowID: selectedRowID ?? rows.first?.id ?? "", text: reason)
        publish(sections, resetSelection: false)
        return false
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

    private func activate(_ state: PageState, restoring: Bool) {
        notice = nil
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
