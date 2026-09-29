import AppKit
import CmuxFileSearch
import CmuxFoundation

/// The right sidebar's Find mode: query bar, status line and grouped results.
///
/// One panel shows the search of the workspace its store currently follows.
/// Each workspace's query, options and results live in a ``FileSearchSession``
/// held by the store, so switching workspaces or sidebar modes restores them.
@MainActor
final class FileSearchPanelView: NSView {
    let coordinator: FileExplorerPanelView.Coordinator
    let queryBar = FileSearchQueryBar()
    let resultsView = FileExplorerSearchResultsTableView()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let resultsScrollView = NSScrollView()
    private let statusRow = NSStackView()
    private let collapseButton = NSButton()
    private let clearButton = NSButton()
    private let refreshButton = NSButton()

    private(set) var session: FileSearchSession
    private var sessionKey: UUID?
    private weak var sessionCache: FileSearchSessionCache?
    private let unscopedSessionKey = UUID()
    private let sessionFactory: @MainActor () -> FileSearchSession
    var historyCursor = FileSearchHistoryCursor()
    var history: FileSearchHistory

    private(set) var rootPath = ""
    private(set) var scope: FileSearchScope = .unsupported
    private(set) var contentRevision = 0
    private(set) var resourceContextID: UUID?
    /// True while Find is the visible presentation.
    private(set) var isActive = false

    /// Escape in an empty query. The container moves focus out of Find.
    var onDismiss: (() -> Void)?
    var onFocus: (() -> Void)?

    lazy var pendingPreviewDrag = FilePreviewNativeDragPendingOwnership { [weak self] tokenID in
        self?.previewWriterDidDeallocate(tokenID: tokenID)
    }

    /// - Parameter makeSession: Builds a workspace session. Tests inject
    ///   sessions whose engines use a manual clock.
    init(
        coordinator: FileExplorerPanelView.Coordinator,
        makeSession: @escaping @MainActor () -> FileSearchSession = { FileSearchSession() }
    ) {
        self.coordinator = coordinator
        sessionFactory = makeSession
        session = makeSession()
        history = FileSearchHistoryDefaults.load()
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func build() {
        queryBar.translatesAutoresizingMaskIntoConstraints = false
        queryBar.queryField.delegate = self
        queryBar.queryField.onCancel = { [weak self] in self?.handleEscape() }
        queryBar.queryField.onCommit = { [weak self] in self?.commitFromQueryField() }
        queryBar.queryField.onNavigateMatch = { [weak self] delta in self?.navigateMatch(by: delta) }
        queryBar.queryField.onFocus = { [weak self] in self?.onFocus?() }
        queryBar.onQueryChanged = { [weak self] immediate in self?.queryDidChange(immediate: immediate) }
        queryBar.onDetailsVisibilityChanged = { [weak self] visible in self?.session.showsDetails = visible }
        for field in [queryBar.includeField, queryBar.excludeField] {
            field.onCommit = { [weak self] in self?.runSearchNow() }
            field.onCancel = { [weak self] in self?.focusQueryField(seed: nil) }
            field.onFocus = { [weak self] in self?.onFocus?() }
        }
        addSubview(queryBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("FileSearchStatus")

        configureToolbarButton(
            refreshButton,
            symbol: "arrow.clockwise",
            label: String(localized: "fileSearch.action.refresh", defaultValue: "Refresh"),
            identifier: "FileSearchRefresh",
            action: #selector(refreshPressed(_:))
        )
        configureToolbarButton(
            clearButton,
            symbol: "xmark.circle",
            label: String(localized: "fileSearch.action.clear", defaultValue: "Clear Search Results"),
            identifier: "FileSearchClear",
            action: #selector(clearPressed(_:))
        )
        configureToolbarButton(
            collapseButton,
            symbol: "rectangle.compress.vertical",
            label: String(localized: "fileSearch.action.collapseAll", defaultValue: "Collapse All"),
            identifier: "FileSearchCollapseAll",
            action: #selector(collapseOrExpandAllPressed(_:))
        )
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 2
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.setViews([statusLabel, refreshButton, collapseButton, clearButton], in: .leading)
        addSubview(statusRow)

        configureResultsView()
        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        resultsScrollView.hasVerticalScroller = true
        resultsScrollView.hasHorizontalScroller = false
        resultsScrollView.horizontalScrollElasticity = .none
        resultsScrollView.autohidesScrollers = true
        resultsScrollView.borderType = .noBorder
        resultsScrollView.drawsBackground = false
        resultsScrollView.documentView = resultsView
        addSubview(resultsScrollView)

        NSLayoutConstraint.activate([
            queryBar.topAnchor.constraint(equalTo: topAnchor),
            queryBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            queryBar.trailingAnchor.constraint(equalTo: trailingAnchor),

            statusRow.topAnchor.constraint(equalTo: queryBar.bottomAnchor),
            statusRow.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SidebarSearchField.leadingPadding + 4
            ),
            statusRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            resultsScrollView.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 2),
            resultsScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultsScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyFontScale()
    }

    private func configureResultsView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("searchResult"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        resultsView.addTableColumn(column)
        resultsView.headerView = nil
        resultsView.usesAlternatingRowBackgroundColors = false
        resultsView.style = .plain
        resultsView.selectionHighlightStyle = .regular
        resultsView.backgroundColor = .clear
        resultsView.rowHeight = FileSearchResultMetrics.rowHeight
        resultsView.usesAutomaticRowHeights = false
        resultsView.allowsMultipleSelection = true
        resultsView.intercellSpacing = NSSize(width: 0, height: 0)
        resultsView.setAccessibilityIdentifier("FileSearchResults")
        resultsView.dataSource = self
        resultsView.delegate = self
        resultsView.target = self
        resultsView.doubleAction = #selector(openClickedResult(_:))
        resultsView.setDraggingSourceOperationMask(.move, forLocal: true)
        resultsView.onCommit = { [weak self] in self?.openSelectedResult() }
        resultsView.onCancel = { [weak self] in self?.handleEscape() }
        resultsView.onNavigateMatch = { [weak self] delta in self?.navigateMatch(by: delta) }
        resultsView.onExitTop = { [weak self] in _ = self?.focusQueryField(seed: nil) }
        resultsView.onDisclosure = { [weak self] action in self?.applyDisclosure(action) }
        resultsView.onFocus = { [weak self] in self?.onFocus?() }
        resultsView.onNativeDragPointerBoundary = { [weak self] in self?.prepareForNativeDragBoundary() }
        resultsView.onModeShortcut = { [weak coordinator] mode, window in
            coordinator?.handleModeShortcut(mode, in: window) ?? false
        }
        let menu = NSMenu()
        menu.delegate = self
        resultsView.menu = menu
    }

    private func configureToolbarButton(
        _ button: NSButton,
        symbol: String,
        label: String,
        identifier: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.target = self
        button.action = action
        button.refusesFirstResponder = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    func applyFontScale() {
        queryBar.applyFontScale()
        statusLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        let rowHeight = FileSearchResultMetrics.rowHeight
        if resultsView.rowHeight != rowHeight {
            resultsView.rowHeight = rowHeight
            resultsView.reloadData()
        }
    }

    /// Hides the status line and results while no folder is open or the
    /// root is loading; the query bar stays so editing is never interrupted.
    /// Returns whether anything changed.
    @discardableResult
    func setResultsHidden(_ hidden: Bool) -> Bool {
        guard resultsScrollView.isHidden != hidden else { return false }
        resultsScrollView.isHidden = hidden
        statusRow.alphaValue = hidden ? 0 : 1
        return true
    }

    // MARK: - Scope and sessions

    /// Follows the store's workspace, root, provider and content revision.
    /// A hidden panel only records them; it takes its workspace's session
    /// when it becomes active, so it never competes with the visible one.
    func update(store: FileExplorerStore) {
        let nextKey = store.workspaceRootIdentity ?? unscopedSessionKey
        let nextScope = FileSearchScope(provider: store.provider)
        let nextRoot = store.rootPath
        let nextRevision = store.contentRevision
        let targetChanged = nextScope != scope || nextRoot != rootPath
        let revisionChanged = nextRevision != contentRevision
        sessionCache = store.fileSearchSessions
        scope = nextScope
        rootPath = nextRoot
        contentRevision = nextRevision
        resourceContextID = store.resourceContextID
        let workspaceChanged = nextKey != sessionKey
        sessionKey = nextKey
        guard isActive else { return }

        if workspaceChanged || session.owner !== self {
            syncSession()
        } else if targetChanged {
            runSearchNow()
        } else if revisionChanged {
            refreshAfterContentChange()
        } else {
            updateStatus()
        }
    }

    /// Find became visible or hidden. Hiding stops a running search but
    /// keeps its results; showing again searches if they are stale.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            syncSession()
        } else {
            recordHistory()
            if session.engine.isSearching { session.engine.cancel(clearResults: false) }
            detach(session)
        }
    }

    /// Shows the session of the current workspace.
    private func syncSession() {
        let next = sessionKey.flatMap { key in sessionCache?.session(for: key, make: sessionFactory) } ?? session
        if next !== session {
            if session.engine.isSearching { session.engine.cancel(clearResults: false) }
            detach(session)
            session = next
        }
        attach(session)
        refreshIfStale()
    }

    private func attach(_ session: FileSearchSession) {
        session.owner = self
        session.engine.onEvent = { [weak self, weak session] event in
            guard let self, let session, session === self.session else { return }
            self.handle(event)
        }
        historyCursor.reset()
        queryBar.show(query: session.query, showsDetails: session.showsDetails)
        reloadRows()
        updateStatus()
    }

    private func detach(_ session: FileSearchSession) {
        guard session.owner === self else { return }
        session.owner = nil
        session.engine.onEvent = nil
    }

    /// Searches when the shown results do not match the current query and
    /// target. The content revision is not compared: the store reloads (and
    /// bumps it) on every workspace switch, and returning to a workspace
    /// should show its results rather than restart the search. Later content
    /// changes refresh through ``refreshAfterContentChange()``.
    private func refreshIfStale() {
        guard isActive else {
            updateStatus()
            return
        }
        let engine = session.engine
        let isCurrent = engine.activeRequest.map { request in
            request.query == session.query && request.rootPath == rootPath &&
                request.scopeIdentity == scope.identity
        } ?? false
        if isCurrent, engine.phase != .idle {
            updateStatus()
            return
        }
        runSearchNow()
    }

    /// A content revision during a search waits for that search to finish,
    /// so a busy tree cannot keep restarting it.
    private func refreshAfterContentChange() {
        guard isActive, !session.query.isEmpty else { return }
        if session.engine.isSearching {
            session.needsRefreshAfterSearch = true
        } else {
            runSearchNow()
        }
    }

    // MARK: - Running searches

    /// The request for the current query, or `nil` when this scope cannot be searched.
    func currentRequest() -> FileSearchRequest? {
        guard let backend = session.backendOverride ?? scope.backend else { return nil }
        return FileSearchRequest(
            query: session.query,
            rootPath: rootPath,
            scopeIdentity: scope.identity,
            contentRevision: contentRevision,
            backend: backend
        )
    }

    func runSearchNow() {
        session.needsRefreshAfterSearch = false
        session.prepare(rootPath: rootPath)
        guard let request = currentRequest() else {
            session.engine.cancel(clearResults: true)
            updateStatus()
            return
        }
        session.engine.start(request)
        updateStatus()
    }

    private func scheduleSearch() {
        session.needsRefreshAfterSearch = false
        session.prepare(rootPath: rootPath)
        guard let request = currentRequest() else {
            session.engine.cancel(clearResults: true)
            updateStatus()
            return
        }
        session.engine.schedule(request)
    }

    func queryDidChange(immediate: Bool) {
        session.query = queryBar.query
        session.showsDetails = queryBar.showsDetails
        guard isActive else { return }
        if immediate {
            runSearchNow()
        } else {
            scheduleSearch()
        }
    }

    // MARK: - Engine events

    private func handle(_ event: FileSearchEngineEvent) {
        switch event {
        case .reset:
            reloadRows()
        case .changed(let change):
            apply(change)
        case .phase(let phase):
            if case .finished = phase, session.needsRefreshAfterSearch {
                runSearchNow()
                return
            }
        }
        updateStatus()
    }

    /// Applies one batch to the table, appending rows rather than reloading.
    private func apply(_ change: FileSearchTreeChange) {
        let hadSelection = resultsView.selectedRow >= 0
        switch session.rows.apply(change) {
        case .appended(let inserted, let refreshed):
            if !inserted.isEmpty {
                resultsView.insertRows(at: IndexSet(integersIn: inserted), withAnimation: [])
            }
            for row in refreshed { refreshFileRow(at: row) }
        case .reload:
            resultsView.reloadData()
        }
        if !hadSelection, session.rows.count > 1 {
            resultsView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        }
    }

    private func refreshFileRow(at row: Int) {
        guard let file = item(atRow: row) as? FileSearchFileNode,
              let cell = resultsView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileSearchFileCellView else { return }
        cell.configure(with: file)
    }

    /// Rebuilds the rows from the tree, for a reset or an expansion change.
    func reloadRows() {
        session.rows.rebuild()
        resultsView.reloadData()
    }

    /// The file or match object shown at `row`.
    func item(atRow row: Int) -> AnyObject? {
        guard row >= 0, row < session.rows.count else { return nil }
        let position = session.rows.rows[row]
        let file = session.engine.tree.files[position.fileIndex]
        if let matchIndex = position.matchIndex { return file.matchNode(at: matchIndex) }
        return file
    }

    /// The row showing `item`, when it is visible.
    func row(for item: AnyObject) -> Int? {
        let tree = session.engine.tree
        if let node = item as? FileSearchMatchNode, let position = tree.position(of: node) {
            return session.rows.row(of: position)
        }
        if let file = item as? FileSearchFileNode, let index = tree.index(of: file) {
            return session.rows.row(of: FileSearchResultPosition(fileIndex: index, matchIndex: nil))
        }
        return nil
    }

    /// Expands or collapses one file, keeping it selected.
    func setExpanded(_ expanded: Bool, file: FileSearchFileNode) {
        guard file.isExpanded != expanded else { return }
        file.isExpanded = expanded
        reloadRows()
        if let row = row(for: file) {
            resultsView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            resultsView.scrollRowToVisible(row)
        }
        updateStatus()
    }

    private func applyDisclosure(_ action: RightSidebarKeyboardNavigation.DisclosureAction) {
        let selected = item(atRow: resultsView.selectedRow)
        switch action {
        case .expand:
            if let file = selected as? FileSearchFileNode {
                if file.isExpanded { resultsView.moveSelection(by: 1) } else { setExpanded(true, file: file) }
            }
        case .collapse:
            if let file = selected as? FileSearchFileNode {
                setExpanded(false, file: file)
            } else if let node = selected as? FileSearchMatchNode, let row = row(for: node.file) {
                resultsView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                resultsView.scrollRowToVisible(row)
            }
        }
    }

    func updateStatus() {
        let engine = session.engine
        let query = session.query
        let regexError: String?
        if case .finished(.failed(.invalidRegex(let detail))) = engine.phase {
            regexError = FileSearchStatusText.regexError(detail: detail)
        } else {
            regexError = nil
        }
        queryBar.setRegexError(regexError)
        let text: String?
        if regexError != nil {
            text = nil
        } else if isActive, !query.isEmpty, currentRequest() == nil {
            text = FileSearchStatusText.unsupported
        } else {
            text = FileSearchStatusText.text(
                phase: engine.phase,
                matchCount: engine.tree.matchCount,
                fileCount: engine.tree.fileCount,
                scope: scope,
                hasQuery: !query.isEmpty
            )
        }
        let display = text ?? ""
        if statusLabel.stringValue != display { statusLabel.stringValue = display }
        statusLabel.isHidden = text == nil
        let hasResults = !engine.tree.isEmpty
        collapseButton.isEnabled = hasResults
        clearButton.isEnabled = hasResults || !query.isEmpty
        refreshButton.isEnabled = !query.isEmpty
        statusRow.isHidden = query.isEmpty && !hasResults
        updateCollapseButton()
    }

    private func updateCollapseButton() {
        let anyExpanded = session.engine.tree.files.contains { $0.isExpanded }
        let label = anyExpanded
            ? String(localized: "fileSearch.action.collapseAll", defaultValue: "Collapse All")
            : String(localized: "fileSearch.action.expandAll", defaultValue: "Expand All")
        let symbol = anyExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
        if collapseButton.toolTip != label {
            collapseButton.toolTip = label
            collapseButton.setAccessibilityLabel(label)
            collapseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        }
    }

    // MARK: - Toolbar actions

    @objc private func refreshPressed(_ sender: Any?) {
        runSearchNow()
    }

    @objc func clearPressed(_ sender: Any?) {
        clearSearch()
    }

    @objc private func collapseOrExpandAllPressed(_ sender: Any?) {
        let files = session.engine.tree.files
        let expand = !files.contains { $0.isExpanded }
        setAllExpanded(expand)
    }

    func setAllExpanded(_ expand: Bool) {
        for file in session.engine.tree.files {
            file.isExpanded = expand
        }
        reloadRows()
        updateStatus()
    }

    /// Empties the query and results.
    func clearSearch() {
        recordHistory()
        session.query.pattern = ""
        queryBar.queryField.stringValue = ""
        historyCursor.reset()
        session.engine.cancel(clearResults: true)
        updateStatus()
    }

    /// Saves the current pattern to search history.
    func recordHistory() {
        let pattern = session.query.pattern
        guard !pattern.isEmpty, history.entries.last != pattern else { return }
        FileSearchHistoryDefaults.record(pattern)
        history = FileSearchHistoryDefaults.load()
    }

    /// True when `responder` is part of Find.
    func ownsResponder(_ responder: NSResponder) -> Bool {
        if responder === resultsView || queryBar.ownsResponder(responder) { return true }
        var view = responder as? NSView
        while let candidate = view {
            if candidate === self { return true }
            view = candidate.superview
        }
        return false
    }
}
