import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFiles

/// The Files sidebar: Favorites and Locations in a source-list table.
///
/// Rows are value snapshots (``FileSidebarRow``) and the view talks back
/// through ``FileSidebarActions``; it never holds the sidebar model. Drop a
/// folder between Favorites to add it (or move it, for a Favorite dragged
/// within the list); drop items onto a row to copy or move them there.
@MainActor
final class FileSidebarView: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view: NSView
    private let scroll = NSScrollView()
    private let table = FileTableView()
    private let actions: FileSidebarActions
    private var rows: [FileSidebarRow] = []
    private var current: URL?
    private var applying = false

    init(actions: FileSidebarActions) {
        self.actions = actions
        view = scroll
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("place"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.menuProvider = { [weak self] row in self?.menu(for: row) }
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask([.copy, .link], forLocal: false)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
    }

    /// Shows these rows, highlighting the one at `folder`.
    func show(_ rows: [FileSidebarRow], current folder: URL) {
        if rows != self.rows {
            self.rows = rows
            table.reloadData()
        }
        current = folder.standardizedFileURL
        applying = true
        if let index = rows.firstIndex(where: { $0.url?.standardizedFileURL == current }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        applying = false
    }

    @objc private func clicked() {
        guard let row = table.clickedRowIfValid, rows.indices.contains(row), let url = rows[row].url else { return }
        actions.open(url)
    }

    private func menu(for row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        let menu = NSMenu()
        switch rows[row] {
        case .favorite(let url, _, _):
            menu.addItem(menuItem(FilesStrings.removeFromSidebar) { [actions] in actions.remove(url) })
        case .volume(let volume, _) where volume.isEjectable:
            menu.addItem(menuItem(FilesStrings.eject) { [actions] in actions.eject(volume) })
        default:
            return nil
        }
        return menu
    }

    private func menuItem(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuFired(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = run
        return item
    }

    @objc private func menuFired(_ item: NSMenuItem) { (item.representedObject as? () -> Void)?() }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        applying || rows[row].url != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: FileSidebarCell.identifier, owner: nil) as? FileSidebarCell)
            ?? FileSidebarCell()
        cell.show(rows[row]) { [actions] volume in actions.eject(volume) }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard case .favorite(let url, _, _) = rows[row] else { return nil }
        return url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        let urls = FilePasteboard.fileURLs(info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        if operation == .on, rows.indices.contains(row), rows[row].url != nil {
            return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
        }
        // Between rows: only inside Favorites, and only folders.
        let favorites = rows.indices.filter { if case .favorite = rows[$0] { return true } else { return false } }
        guard let first = favorites.first, let last = favorites.last, (first...(last + 1)).contains(row),
              urls.allSatisfy(\.hasDirectoryPath) || urls.allSatisfy(Self.isFolder) else { return [] }
        return .link
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = FilePasteboard.fileURLs(info.draggingPasteboard)
        if dropOperation == .on, rows.indices.contains(row), let target = rows[row].url {
            let flags = NSEvent.modifierFlags
            actions.drop(urls, target, flags.contains(.option), flags.contains(.command))
            return true
        }
        let favorites = rows.compactMap { row -> URL? in if case .favorite(let url, _, _) = row { url } else { nil } }
        let firstFavorite = rows.firstIndex { if case .favorite = $0 { return true } else { return false } } ?? row
        var slot = row - firstFavorite
        for url in urls {
            // A Favorite dragged further down leaves a gap above its drop slot.
            if let from = favorites.firstIndex(where: { $0.path == url.path }), from < slot { slot -= 1 }
            actions.add(url, slot)
            slot += 1
        }
        return true
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
