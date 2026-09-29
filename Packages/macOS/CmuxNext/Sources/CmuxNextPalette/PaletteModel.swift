public import Foundation
public import Observation

/// The palette's navigation state machine and view model.
///
/// Holds a stack of pages (root list, nested lists, text entry). Each page
/// keeps its own query and selection so popping restores them. Views read
/// the observable properties; the panel controller feeds key commands.
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

    public private(set) var sections: [PaletteResultSection] = []
    public private(set) var selectedRowID: String?
    public private(set) var hoveredRowID: String?
    public private(set) var actionsMenu: PaletteActionsMenuState?
    public private(set) var pageTitle: String = ""
    public private(set) var placeholder: String = ""
    public private(set) var pageSymbol: String = "command"
    /// Titles of the pages above the root, for the breadcrumb.
    public private(set) var breadcrumbs: [String] = []
    public private(set) var isTextInput = false
    public private(set) var isLoading = false
    /// Increments when keyboard navigation moves the selection, so the view
    /// scrolls it into view (mouse hover never scrolls).
    public private(set) var scrollRequest = 0
    /// Increments on every page change so the view refocuses the field.
    public private(set) var pageToken = 0
    /// Drives the open and close animation; owned by the panel controller.
    public var isPresented = false

    // MARK: Non-observable state

    /// Called when a command closes the palette. The controller hides the
    /// panel here; the command's handler runs right after.
    @ObservationIgnored public var onDismiss: (@MainActor () -> Void)?
    /// Injected clock for frecency.
    @ObservationIgnored public var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored public private(set) var frecency: FrecencyStore
    @ObservationIgnored private let persistence: (any FrecencyPersisting)?
    @ObservationIgnored private var stack: [PageState] = []
    @ObservationIgnored private var current: PageState? { stack.last }

    public init(frecency: FrecencyStore? = nil, persistence: (any FrecencyPersisting)? = nil) {
        self.persistence = persistence
        self.frecency = frecency ?? persistence?.load() ?? FrecencyStore()
    }

    // MARK: Derived

    /// Rows in display order.
    public var rows: [PaletteRow] { sections.flatMap(\.rows) }

    public var selectedItem: PaletteItem? {
        guard let selectedRowID else { return nil }
        return rows.first { $0.id == selectedRowID }?.item
    }

    /// Footer title for Return.
    public var primaryTitle: String? {
        guard let item = selectedItem, item.isEnabled else { return nil }
        return item.primary.title
    }

    public var depth: Int { stack.count }

    // MARK: Navigation

    /// Starts over at `page`, discarding the stack. Called on open.
    public func reset(to page: PalettePageSpec) {
        for state in stack { state.cancel() }
        stack = []
        actionsMenu = nil
        hoveredRowID = nil
        push(page)
    }

    public func push(_ page: PalettePageSpec) {
        let state = PageState(kind: .list(page))
        stack.append(state)
        actionsMenu = nil
        activate(state, restoring: false)
        load(state)
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
    }

    // MARK: Keyboard

    /// Applies a key command. Returns whether it was consumed; unconsumed
    /// commands fall through to the text field.
    @discardableResult
    public func handle(_ command: PaletteKeyCommand) -> Bool {
        if actionsMenu != nil, handleActionsMenu(command) { return true }
        switch command {
        case .moveUp: moveSelection(by: -1, wrap: true)
        case .moveDown: moveSelection(by: 1, wrap: true)
        case .pageUp: moveSelection(by: -Self.pageStep, wrap: false)
        case .pageDown: moveSelection(by: Self.pageStep, wrap: false)
        case .moveToFirst: selectRow(at: 0, scroll: true)
        case .moveToLast: selectRow(at: rows.count - 1, scroll: true)
        case .submit:
            guard let item = selectedItem else { return false }
            run(item.primary, of: item)
        case .submitAlternate:
            guard let item = selectedItem else { return false }
            run(item.alternate ?? item.primary, of: item)
        case .toggleActions, .openActions:
            return openActionsMenu()
        case .closeActions:
            return false
        case .escape:
            if pop() { return true }
            if !query.isEmpty {
                query = ""
                return true
            }
            onDismiss?()
        case .back:
            guard query.isEmpty else { return false }
            return pop()
        case .actionsFilterAppend, .actionsFilterDeleteBackward:
            return false
        }
        return true
    }

    private func handleActionsMenu(_ command: PaletteKeyCommand) -> Bool {
        guard var menu = actionsMenu else { return false }
        let count = menu.visibleCommands.count
        switch command {
        case .moveUp, .moveDown:
            guard count > 0 else { return true }
            let delta = command == .moveUp ? -1 : 1
            menu.selectedIndex = (menu.selectedIndex + delta + count) % count
            actionsMenu = menu
        case .moveToFirst, .pageUp:
            menu.selectedIndex = 0
            actionsMenu = menu
        case .moveToLast, .pageDown:
            menu.selectedIndex = max(0, count - 1)
            actionsMenu = menu
        case .submit, .submitAlternate:
            let visible = menu.visibleCommands
            guard visible.indices.contains(menu.selectedIndex),
                  let item = rows.first(where: { $0.id == menu.itemID })?.item
            else { return true }
            let command = visible[menu.selectedIndex]
            actionsMenu = nil
            run(command, of: item)
        case .toggleActions, .closeActions, .escape:
            actionsMenu = nil
        case .openActions:
            break
        case .back:
            return false
        case .actionsFilterAppend(let text):
            menu.filter += text
            menu.selectedIndex = 0
            actionsMenu = menu
        case .actionsFilterDeleteBackward:
            if menu.filter.isEmpty {
                actionsMenu = nil
            } else {
                menu.filter.removeLast()
                menu.selectedIndex = 0
                actionsMenu = menu
            }
        }
        return true
    }

    private func openActionsMenu() -> Bool {
        guard let item = selectedItem, item.isEnabled else { return false }
        actionsMenu = PaletteActionsMenuState(itemID: item.id, itemTitle: item.title, commands: item.allCommands)
        return true
    }

    /// Runs the command at `index` of the visible Actions menu (mouse).
    public func runActionsMenuCommand(at index: Int) {
        guard var menu = actionsMenu else { return }
        menu.selectedIndex = index
        actionsMenu = menu
        handle(.submit)
    }

    public func closeActionsMenu() {
        actionsMenu = nil
    }

    // MARK: Mouse

    public func hover(_ rowID: String?) {
        if hoveredRowID != rowID { hoveredRowID = rowID }
    }

    /// Click: select the row and run its primary command.
    public func activate(rowID: String) {
        selectedRowID = rowID
        actionsMenu = nil
        handle(.submit)
    }

    public func select(rowID: String) {
        guard rows.contains(where: { $0.id == rowID }) else { return }
        selectedRowID = rowID
    }

    // MARK: Running commands

    /// Runs `command` for `item`, recording usage.
    public func run(_ command: PaletteCommand, of item: PaletteItem) {
        guard item.isEnabled else { return }
        if let key = item.frecencyKey {
            frecency.record(key, at: now())
            persistence?.save(frecency)
        }
        switch command.effect {
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

    // MARK: Internals

    static let pageStep = 8

    private func activate(_ state: PageState, restoring: Bool) {
        // Assign the query first; its didSet refreshes against `current`.
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
        if query != state.query {
            query = state.query
        } else {
            refreshResults(resetSelection: true)
        }
        if restoring, let savedSelection, rows.contains(where: { $0.id == savedSelection }) {
            selectedRowID = savedSelection
            scrollRequest += 1
        }
        pageToken += 1
    }

    private func load(_ state: PageState) {
        guard case .list(let page) = state.kind else { return }
        state.cancel()
        var pending = Set<String>()
        for provider in page.providers {
            if let items = provider.immediateItems {
                state.providerItems[provider.id] = items
            } else {
                pending.insert(provider.id)
            }
        }
        state.pendingProviders = pending
        state.invalidateIndex()
        if state === current {
            isLoading = !pending.isEmpty
            refreshResults(resetSelection: false)
        }
        for provider in page.providers where pending.contains(provider.id) {
            let providerID = provider.id
            state.tasks.append(Task { [weak self, weak state] in
                let items = await provider.items()
                guard !Task.isCancelled, let self, let state else { return }
                state.providerItems[providerID] = items
                state.pendingProviders.remove(providerID)
                state.invalidateIndex()
                if state === self.current {
                    self.isLoading = !state.pendingProviders.isEmpty
                    self.refreshResults(resetSelection: false)
                }
            })
        }
    }

    private func refreshResults(resetSelection: Bool) {
        guard let state = current else {
            sections = []
            selectedRowID = nil
            return
        }
        switch state.kind {
        case .textInput(let spec):
            let text = state.query
            let valid = spec.isValid(text)
            let item = PaletteItem(
                id: "submit",
                title: spec.submitTitle(text),
                symbol: spec.symbol,
                keycaps: ["↩"],
                isEnabled: valid,
                primary: PaletteCommand(id: "submit", title: PaletteStrings.submit, symbol: "return", effect: .perform {
                    spec.submit(text)
                }),
                frecencyKey: nil
            )
            sections = [PaletteResultSection(section: .results, rows: [PaletteRow(item: item, highlights: [], score: 0)])]
            selectedRowID = item.id
        case .list(let page):
            let index = state.index(for: page)
            sections = PaletteRanker.rank(
                index: index,
                query: state.query,
                frecency: frecency,
                now: now(),
                showsRecent: page.showsRecent
            )
            let rows = self.rows
            if resetSelection || selectedRowID == nil || !rows.contains(where: { $0.id == selectedRowID }) {
                selectedRowID = rows.first?.id
                if resetSelection { scrollRequest += 1 }
            }
            if let menu = actionsMenu, !rows.contains(where: { $0.id == menu.itemID }) {
                actionsMenu = nil
            }
        }
        state.selectedRowID = selectedRowID
    }

    private func moveSelection(by delta: Int, wrap: Bool) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex { $0.id == selectedRowID } ?? -1
        var next = currentIndex + delta
        if wrap {
            next = ((next % rows.count) + rows.count) % rows.count
        } else {
            next = min(max(next, 0), rows.count - 1)
        }
        selectRow(at: next, scroll: true)
    }

    private func selectRow(at index: Int, scroll: Bool) {
        let rows = self.rows
        guard rows.indices.contains(index) else { return }
        selectedRowID = rows[index].id
        current?.selectedRowID = selectedRowID
        if scroll { scrollRequest += 1 }
    }
}
