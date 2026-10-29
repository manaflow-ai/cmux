import AppKit
import CmuxNextCompatAppKit
import CmuxNextFiles
import CmuxNextWakeups

/// The column layout: Miller columns over `NSBrowser`, one column per folder
/// from `/` to the folder shown. Columns list off the main actor: a column
/// whose folder is not read yet shows empty and fills when the listing lands.
@MainActor
final class FileColumnsView: NSObject, FileContentView, NSBrowserDelegate {
    let view: NSView
    var focusView: NSView { browser }
    private let browser = FileBrowserControl()
    private let actions: FilesPaneActions
    private let icons: FileIconProvider
    private let lister: any DirectoryListing
    /// The app's main-thread scheduler: each column's listing lands as one visible task on it.
    private let mainWork: MainWorkScheduler
    private var listings: [String: [FileColumnNode]] = [:]
    private var loading: Set<String> = []
    private let root = FileColumnNode(entry: FileEntry(url: URL(fileURLWithPath: "/"), kind: .folder))
    private var showsHidden = false
    private var applying = false

    init(actions: FilesPaneActions, icons: FileIconProvider, lister: any DirectoryListing, mainWork: MainWorkScheduler) {
        self.actions = actions
        self.icons = icons
        self.lister = lister
        self.mainWork = mainWork
        view = browser
        super.init()
        browser.delegate = self
        browser.target = self
        browser.action = #selector(clicked)
        browser.doubleAction = #selector(doubleClicked)
        browser.allowsMultipleSelection = true
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 180
        browser.isTitled = false
        browser.keyHandler = { [weak self] event in self?.actions.key(event) ?? false }
    }

    /// Whether columns list hidden items (follows the pane's Cmd+Shift+. toggle).
    func setShowsHidden(_ value: Bool) {
        guard value != showsHidden else { return }
        showsHidden = value
        listings.removeAll()
        browser.loadColumnZero()
    }

    func show(_ entries: [FileEntry], of folder: URL, selection: Set<String>) {
        listings[folder.standardizedFileURL.path] = FileSortOrder().sorted(entries).map(FileColumnNode.init)
        var path = folder.standardizedFileURL.path
        if selection.count == 1, let name = selection.first { path = (path as NSString).appendingPathComponent(name) }
        guard browser.path() != path else { return }
        applying = true
        browser.setPath(path)
        applying = false
    }

    func reveal(_ name: String) {}

    /// Asks each loaded column's rows for their cells again (``browser(_:willDisplayCell:atRow:column:)`` sets the
    /// icon). `reloadColumn(_:)` would make the column it reloads the last one and close the deeper columns open.
    func redrawIcons() {
        guard browser.lastColumn >= 0 else { return }
        for column in 0...browser.lastColumn {
            guard let parent = browser.parentForItems(inColumn: column) as? FileColumnNode,
                  let rows = listings[parent.entry.url.standardizedFileURL.path], !rows.isEmpty else { continue }
            browser.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), inColumn: column)
        }
    }
    func beginRename(_ name: String) {}

    /// A click that leaves no selection sends the action with selectedColumn -1 (#24776): the
    /// checked accessors (CmuxNextCompat) answer nil there instead of raising.
    @objc private func clicked() {
        guard !applying, let node = browser.selectedItemIfValid as? FileColumnNode else { return }
        actions.browse(node.entry.url)
    }

    @objc private func doubleClicked() {
        guard let node = browser.clickedItemIfValid as? FileColumnNode else { return }
        if node.entry.kind != .folder { actions.activate(node.entry) }
    }

    private func children(of node: FileColumnNode) -> [FileColumnNode] {
        let path = node.entry.url.standardizedFileURL.path
        if let listed = listings[path] { return listed }
        guard !loading.contains(path) else { return [] }
        loading.insert(path)
        let url = node.entry.url
        let hidden = showsHidden
        // The listing reads off main; its column fills in one userBlocking task, the completion of the
        // person's click on the folder (p06-scheduler rule 2). The off-main task holds only Sendable
        // values; the view and the node stay in a main-actor closure.
        let land: @MainActor @Sendable ([FileEntry]) -> Void = { [weak self] entries in
            self?.listed(entries, of: node, at: path, hidden: hidden)
        }
        let lister = lister, mainWork = mainWork
        // task-owner: one folder listing off main; ends when its column reloads
        Task { @concurrent in
            let entries = (try? await lister.list(url)) ?? []
            mainWork.postFromAnyThread(.userBlocking, owner: "FileColumns.listed") { land(entries) }
        }
        return []
    }

    /// Keeps `node`'s listing and reloads the columns that show its children.
    private func listed(_ entries: [FileEntry], of node: FileColumnNode, at path: String, hidden: Bool) {
        loading.remove(path)
        listings[path] = FileSortOrder().sorted(entries.filter { hidden || !$0.isHidden }).map(FileColumnNode.init)
        guard browser.lastColumn >= 0 else { return }
        for column in 0...browser.lastColumn where browser.parentForItems(inColumn: column) as? FileColumnNode === node {
            browser.reloadColumn(column)
        }
    }

    // MARK: NSBrowserDelegate (item-based)

    func rootItem(for browser: NSBrowser) -> Any? { root }

    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileColumnNode, node.entry.kind == .folder else { return 0 }
        return children(of: node).count
    }

    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileColumnNode else { return root }
        let list = children(of: node)
        return index < list.count ? list[index] : root
    }

    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
        (item as? FileColumnNode)?.entry.kind != .folder
    }

    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
        (item as? FileColumnNode)?.entry.name
    }

    func browser(_ browser: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell, let node = browser.item(ifValidRow: row, inColumn: column) as? FileColumnNode else { return }
        let image = icons.icon(for: node.entry).copy() as? NSImage
        image?.size = NSSize(width: 16, height: 16)
        cell.image = image
    }
}

/// One item of the column view (`NSBrowser` needs stable object items).
final class FileColumnNode: NSObject {
    let entry: FileEntry
    init(entry: FileEntry) { self.entry = entry }
}
