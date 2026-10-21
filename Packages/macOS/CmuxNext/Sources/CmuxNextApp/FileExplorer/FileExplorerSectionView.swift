import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The right sidebar's Files section (classic's file explorer): the focused
/// terminal's folder as a tree. Click selects, double-click, Return and
/// Cmd-Down open, the right-click menu runs the explorer actions. Every row
/// runs through the registry, the path the palette, keys and CLI take.
final class FileExplorerSectionView: NSView, RightSidebarRefreshing, NSTableViewDataSource, NSTableViewDelegate {
    let model: FileExplorerModel
    private let rootFolder: @MainActor @Sendable () -> URL?
    private let perform: @MainActor (String) -> Void
    private let header = NSTextField(labelWithString: "")
    let table = FileExplorerTableView()
    private let scroll = NSScrollView()
    private var rows: [FileExplorerRow] = []
    private var observation: Task<Void, Never>?
    private var following: Task<Void, Never>?

    /// - Parameters:
    ///   - model: The tree (the handlers act on its selection).
    ///   - rootFolder: The focused terminal's folder, nil when the focused tab has no local folder
    ///     (the tree keeps its root). Read in an observation, so a `cd` there moves the tree.
    ///   - perform: Runs an explorer action with `fileExplorerFocused` (``FileExplorerHandlers``).
    init(model: FileExplorerModel, rootFolder: @escaping @MainActor @Sendable () -> URL?, perform: @escaping @MainActor (String) -> Void) {
        self.model = model
        self.rootFolder = rootFolder
        self.perform = perform
        super.init(frame: NSRect(x: 0, y: 0, width: RightSidebarModel.width, height: 400))
        build()
        observation = Task { [weak self] in
            guard let model = self?.model else { return }
            for await _ in ObservationStream({ [model] in (model.rows, model.root, model.failure) }) {
                self?.render()
            }
        }
        refresh()
        // The focused terminal's folder changes (a `cd`): the tree follows. A focus change the
        // observation cannot see comes through ``follow()`` (FileExplorerService.focusChanged).
        following = Task { [weak self, rootFolder] in
            for await folder in ObservationStream({ rootFolder() }) {
                guard let self else { return }
                if let folder { self.show(folder) }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
            following?.cancel()
        }
    }

    /// Roots the tree at the focused terminal's folder each time the section shows (home before
    /// any terminal had focus).
    func refresh() {
        show(rootFolder() ?? model.root ?? FileManager.default.homeDirectoryForCurrentUser, relist: true)
    }

    /// Focus moved: the tree roots at the newly focused terminal's folder; a tab with no local
    /// folder keeps the tree where it is.
    func follow() {
        if let folder = rootFolder() { show(folder) }
    }

    /// Roots the tree at `folder`; the same folder lists again only when `relist`.
    private func show(_ folder: URL, relist: Bool = false) {
        guard relist || folder.standardizedFileURL != model.root else { return }
        let model = model
        // task-owner: one listing; a newer one supersedes it (the model's generation).
        Task { await model.setRoot(folder) }
    }

    private func build() {
        header.font = Typography.caption
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingMiddle
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .small
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.perform = { [weak self] id in self?.perform(id) }
        table.contextMenu = { [weak self] in self?.makeMenu() }
        table.setAccessibilityIdentifier("cmux.fileExplorer")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space3),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.space3),
            header.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Metrics.space2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func render() {
        header.stringValue = model.failure ?? model.root.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? FileExplorerStrings.noFolder
        rows = model.rows
        table.reloadData()
        if let selection = model.selection, let index = rows.firstIndex(where: { $0.url == selection }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        perform("fileExplorerOpenSelection")
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, String)] = [
            ("fileExplorerOpenInCmux", FileExplorerStrings.openInCmux),
            ("fileExplorerOpenWith", FileExplorerStrings.openWith),
            ("fileExplorerReveal", FileExplorerStrings.revealInFinder),
            ("fileExplorerCopyPath", FileExplorerStrings.copyPath),
            ("fileExplorerCopyRelativePath", FileExplorerStrings.copyRelativePath),
        ]
        for (id, title) in items {
            let item = NSMenuItem(title: title, action: #selector(menuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(id)
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("fileExplorer.row")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileExplorerCell ?? FileExplorerCell(identifier: id)
        cell.show(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = table.selectedRow
        model.selection = index >= 0 && index < rows.count ? rows[index].url : nil
    }
}
