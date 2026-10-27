import AppKit
import CmuxNextCompatAppKit
import CmuxNextDesign
import CmuxNextFilesUI
import CmuxNextWakeups

/// The right sidebar's Find section and the Find pane's view: a search field
/// over the focused terminal's folder and one row per matching line. Return
/// in the field searches; double-click or Return on a row opens its file in
/// cmux; the right-click menu reveals or copies the path. Typing searches
/// live once typing pauses (``FindSectionModel/type(_:)``).
final class FindSectionView: NSView, RightSidebarRefreshing, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let model: FindSectionModel
    private let rootFolder: @MainActor () -> URL
    private let effects: any FileExplorerEffects
    let field = NSSearchField() // text-focus-allow: no rounded control owns this sidebar field; its ring is the only focus cue (accessibility).
    private let status = NSTextField(labelWithString: "")
    let table = FindResultsTableView()
    private let scroll = NSScrollView()
    private var results: [RipgrepMatch] = []
    /// This view in the visibility tree: the results render only while it is on screen, and once on show.
    let visibility = ViewVisibility("find")
    var visibilityNode: VisibilityNode { visibility.node }
    private var observation: VisibleObservation<([RipgrepMatch], FindSectionModel.State, URL?)>?
    /// The result to select and the scroll to go back to when the next search finishes
    /// (``restore(query:cursor:scroll:)``).
    private var pendingCursor: String?
    private var pendingScroll: CGPoint?

    /// - Parameters:
    ///   - model: The search (one per section or pane).
    ///   - mainWork: The app's main-thread scheduler its observation runs on.
    ///   - rootFolder: The folder to search now (the focused terminal's, else home).
    ///   - effects: How a result opens, reveals and copies (the file explorer's).
    init(model: FindSectionModel, mainWork: MainWorkScheduler, rootFolder: @escaping @MainActor () -> URL, effects: any FileExplorerEffects) {
        self.model = model
        self.rootFolder = rootFolder
        self.effects = effects
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        build()
        observation = VisibleObservation(visibility.node, owner: "FindSection.render", on: mainWork) { [model] in
            (model.results, model.state, model.root)
        } apply: { [weak self] _ in
            self?.render()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility.place(in: window)
    }

    override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    /// Searches the focused terminal's folder each time the section shows (again, when it changed).
    func refresh() {
        let before = model.root
        model.setRoot(rootFolder())
        if model.root != before, !field.stringValue.isEmpty { submit() }
    }

    private func build() {
        field.placeholderString = FileExplorerStrings.findPlaceholder
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(submit)
        field.delegate = self
        field.font = Typography.body
        status.font = Typography.caption
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .sourceList
        // A source list paints the system sidebar gray; the section sits on the window's ground like
        // the sidebar, so the search strip and the results read as one surface.
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.open = { [weak self] in self?.openSelected() }
        table.contextMenu = { [weak self] in self?.makeMenu() }
        table.setAccessibilityIdentifier("cmux.find.results")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for view in [field, status, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space3),
            field.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space2),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Metrics.space2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: Metrics.space2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func controlTextDidChange(_ notification: Notification) {
        model.type(field.stringValue)
    }

    @objc private func submit() {
        let model = model, text = field.stringValue
        // task-owner: one search; a newer one supersedes it (the model's generation).
        // main-hop-allow: the person's Return; search is the model's main-actor async ripgrep run (RipgrepSearch runs off main); this task only starts it
        Task { await model.search(text) }
    }

    /// The selected result as ``cursor(of:)``: what a discarded Find tab keeps.
    var cursor: String? {
        guard let row = table.selectedRowIfValid, row < results.count else { return nil }
        return Self.cursor(of: results[row])
    }

    /// A result's place: `path:line:column`.
    static func cursor(of match: RipgrepMatch) -> String { "\(match.path):\(match.line):\(match.column)" }

    /// Where the results list is scrolled: what a discarded Find tab keeps with its cursor.
    var resultsScroll: CGPoint { scroll.documentVisibleRect.origin }

    /// Searches for `query` again, then selects the result at `cursor` and scrolls the results back
    /// to `scroll` once they show: a discarded Find tab shown again (FindPaneService).
    func restore(query: String, cursor: String?, scroll: CGPoint? = nil) {
        field.stringValue = query
        pendingCursor = cursor
        pendingScroll = scroll
        submit()
    }

    private func render() {
        results = model.results
        table.reloadData()
        selectPendingCursor()
        let root = model.root.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? FileExplorerStrings.noFolder
        switch model.state {
        case .idle: status.stringValue = root
        case .searching: status.stringValue = FileExplorerStrings.searching(root)
        case .done(let limited):
            status.stringValue = limited ? FindInDirectoryStrings.limited(RipgrepSearch.limit) : FileExplorerStrings.matchCount(results.count)
        case .failed(let reason): status.stringValue = reason
        }
    }

    /// Selects the result and goes back to the scroll ``restore(query:cursor:scroll:)`` asked for,
    /// once its search ends; with no saved scroll, the selected result scrolls into view.
    private func selectPendingCursor() {
        guard pendingCursor != nil || pendingScroll != nil else { return }
        switch model.state {
        case .idle, .searching: return
        case .done, .failed: break
        }
        let cursor = pendingCursor, origin = pendingScroll
        pendingCursor = nil
        pendingScroll = nil
        if let cursor, let row = results.firstIndex(where: { Self.cursor(of: $0) == cursor }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if origin == nil { table.scrollRowToVisible(row) }
        }
        guard let origin else { return }
        // sync-layout: once per restore, so the results have their height before the list scrolls back.
        layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private var selected: RipgrepMatch? {
        guard let row = table.clickedRowIfValid ?? table.selectedRowIfValid, row < results.count else { return nil }
        return results[row]
    }

    @objc private func openClicked() {
        guard table.clickedRowIfValid != nil else { return }
        openSelected()
    }

    private func openSelected() {
        guard let match = selected else { return }
        FindSectionModel.open(match, effects: effects)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [(FileExplorerStrings.openInCmux, #selector(menuOpen)),
                                (FileExplorerStrings.revealInFinder, #selector(menuReveal)),
                                (FileExplorerStrings.copyPath, #selector(menuCopyPath)),
                                (FileExplorerStrings.copyRelativePath, #selector(menuCopyRelativePath))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuOpen() { openSelected() }
    @objc private func menuReveal() { if let match = selected { effects.revealInFinder(URL(fileURLWithPath: match.path)) } }
    @objc private func menuCopyPath() { if let match = selected { effects.copy(match.path) } }
    @objc private func menuCopyRelativePath() { if let match = selected { effects.copy(match.relativePath) } }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("find.row")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FindResultCell ?? FindResultCell(identifier: id)
        cell.show(results[row])
        return cell
    }
}

// A Find section let go while hidden (feature `memoryDiscardSidebarSections`) searches its query again and goes
// back to its selected result and scroll.
extension FindSectionView: SidebarSectionStateKeeping {
    var sectionState: SidebarSectionState {
        SidebarSectionState(scroll: resultsScroll, query: field.stringValue, selection: cursor)
    }

    func restoreSectionState(_ state: SidebarSectionState) {
        guard let query = state.query, !query.isEmpty else { return }
        restore(query: query, cursor: state.selection, scroll: state.scroll)
    }
}
