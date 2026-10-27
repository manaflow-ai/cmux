import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFiles
import CmuxNextFilesUI

/// The right sidebar's Files section (classic's file explorer): the focused
/// terminal's folder as a tree. Click selects, double-click, Return and
/// Cmd-Down open, the right-click menu runs the explorer actions. Every row
/// runs through the registry, the path the palette, keys and CLI take.
final class FileExplorerSectionView: NSView, RightSidebarRefreshing, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let model: FileExplorerModel
    private let rootFolder: @MainActor @Sendable () -> URL?
    private let perform: @MainActor (String) -> Void
    private let rowMenu: @MainActor (_ hasSelection: Bool) -> NSMenu?
    /// Builds the menu's Open With apps submenu (it fills when LaunchServices answers).
    private let openWithMenu: FileExplorerOpenWithMenu?
    private let apps: any FileAppsProviding
    private let effects: any FileExplorerEffects
    private let showError: @MainActor (String) -> Void
    /// The item whose name is being edited (Rename, or a new item's first name).
    private var renaming: URL?
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
    ///   - rowMenu: The right-click menu, the registry's `fileExplorerRow` menu (New File and
    ///     New Folder only when nothing is selected).
    ///   - openWith: Turns the menu's Open With row into the file's apps submenu.
    ///   - apps: The apps that open a file (LaunchServices; a fake in tests).
    ///   - effects: What a rename typed in a row uses besides the file system.
    ///   - showError: Shows why a rename typed in a row failed.
    init(model: FileExplorerModel, rootFolder: @escaping @MainActor @Sendable () -> URL?, perform: @escaping @MainActor (String) -> Void,
         rowMenu: @escaping @MainActor (_ hasSelection: Bool) -> NSMenu?, openWith: FileExplorerOpenWithMenu? = nil,
         apps: any FileAppsProviding = WorkspaceFileApps(),
         effects: any FileExplorerEffects = NullFileExplorerEffects(), showError: @escaping @MainActor (String) -> Void = { _ in }) {
        self.effects = effects
        self.showError = showError
        self.model = model
        self.rootFolder = rootFolder
        self.perform = perform
        self.rowMenu = rowMenu
        openWithMenu = openWith
        self.apps = apps
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
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
        following?.cancel()
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
        // A source list paints the system sidebar gray; the section sits on the window's ground like
        // the sidebar, so the header strip and the tree read as one surface.
        table.backgroundColor = .clear
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
        guard table.clickedRowIfValid != nil else { return }
        perform("fileExplorerOpenSelection")
    }

    /// The right-click menu from the registry; a row's Open With becomes its apps submenu.
    private func makeMenu() -> NSMenu? {
        let row = model.selectedRow
        guard let menu = rowMenu(row != nil) else { return nil }
        // Open as Text only for a page cmux renders (HTML, SVG, Markdown): other files open as text already.
        if let row, row.isFolder || !FileOpenKind(fileName: row.name, isDirectory: false, isPackage: false).opensAsText,
           let index = menu.items.firstIndex(where: { ActionRegistry.menuRun(of: $0)?.id == "fileExplorerOpenAsText" }) {
            menu.removeItem(at: index)
        }
        if let row { openWithMenu?.attach(to: menu, for: row, apps: apps) }
        return menu
    }

    /// Runs one file change through ``FileExplorerCommands``; a failure shows its reason.
    private func edit(_ change: @escaping @MainActor (FileExplorerCommands) async throws -> Void) {
        var commands = FileExplorerCommands(model: model, effects: effects)
        commands.undoManager = window?.undoManager
        let showError = showError
        // task-owner: one file change and a relisting; ends when the folder lists again.
        Task { @MainActor in
            do { try await change(commands) } catch {
                showError((error as? FileExplorerError)?.reason ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// What an explorer action run on this tree needs: its model, its window's undo stack, its rename field.
    var runTarget: FileExplorerRunTarget {
        FileExplorerRunTarget(model: model, undoManager: window?.undoManager, rename: { [weak self] in self?.beginRename($0) })
    }

    /// Edits `item`'s name in its row (Rename, and a new item's first name, as Finder does).
    func beginRename(_ item: URL) {
        let item = item.standardizedFileURL
        render()
        guard let index = rows.firstIndex(where: { $0.url == item }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? FileExplorerCell else { return }
        renaming = item
        cell.beginEditing(delegate: self)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let item = renaming else { return }
        renaming = nil
        (field.superview as? FileExplorerCell)?.endEditing()
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.lastPathComponent else {
            field.stringValue = item.lastPathComponent
            return
        }
        edit { _ = try await $0.rename(item, to: name) }
        window?.makeFirstResponder(table)
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
