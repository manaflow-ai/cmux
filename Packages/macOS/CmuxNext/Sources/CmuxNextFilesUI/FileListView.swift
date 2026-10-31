import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFiles

/// The list layout: an `NSTableView` with Name, Date Modified, Size and Kind
/// columns. Only visible rows have views (the table reuses cells), so a
/// 100 000-item folder scrolls like a 100-item one.
@MainActor
final class FileListView: NSObject, FileContentView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let view: NSView
    var focusView: NSView { table }
    private let scroll = NSScrollView()
    private let table = FileTableView()
    private let actions: FilesPaneActions
    private let icons: FileIconProvider
    private var entries: [FileEntry] = []
    private var folder: URL?
    private var applyingSelection = false
    private var renaming: FileEntry?
    private var displayedFont = Typography.body
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(actions: FilesPaneActions, icons: FileIconProvider) {
        self.actions = actions
        self.icons = icons
        view = scroll
        super.init()
        for (id, title, width) in [("name", FilesStrings.columnName, 280.0), ("modified", FilesStrings.columnModified, 170.0),
                                   ("size", FilesStrings.columnSize, 80.0), ("kind", FilesStrings.columnKind, 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.style = .fullWidth
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.keyHandler = { [weak self] event in self?.actions.key(event) ?? false }
        table.menuProvider = { [weak self] row in
            guard let self else { return nil }
            return self.actions.menu(row >= 0 && row < self.entries.count ? self.entries[row] : nil)
        }
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Both bars thin, on no track, and no header corner (SystemScrollers.follow).
        SystemScrollers.follow(scroll)
    }

    func show(_ entries: [FileEntry], of folder: URL, selection: Set<String>) {
        let sameRows = self.folder == folder && self.entries.count == entries.count && self.entries == entries
        self.entries = entries
        self.folder = folder
        if !sameRows { table.reloadData() }
        let font = Typography.body
        if displayedFont != font {
            displayedFont = font
            table.enumerateAvailableRowViews { row, _ in
                for case let cell as NSTableCellView in row.subviews {
                    cell.textField?.font = font
                    cell.textField?.currentEditor()?.font = font
                }
            }
        }
        applySelection(selection)
    }

    private func applySelection(_ selection: Set<String>) {
        var rows = IndexSet()
        if !selection.isEmpty {
            for (row, entry) in entries.enumerated() where selection.contains(entry.name) { rows.insert(row) }
        }
        guard rows != table.selectedRowIndexes else { return }
        applyingSelection = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        applyingSelection = false
        if let last = rows.last { table.scrollRowToVisible(last) }
    }

    func reveal(_ name: String) {
        guard let row = entries.firstIndex(where: { $0.name == name }) else { return }
        table.scrollRowToVisible(row)
    }

    func beginRename(_ name: String) {
        guard let row = entries.firstIndex(where: { $0.name == name }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renaming = entries[row]
        field.isEditable = true
        field.delegate = self
        table.window?.makeFirstResponder(field)
        // Select the name without its extension, as Finder does.
        let stem = (name as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? name : stem).utf16.count)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let entry = renaming else { return }
        renaming = nil
        field.isEditable = false
        let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
        let newName = field.stringValue
        if movement == NSTextMovement.cancel.rawValue || newName == entry.name {
            field.stringValue = entry.name
        } else {
            actions.rename(entry, newName)
        }
        table.window?.makeFirstResponder(table)
    }

    @objc private func doubleClicked() {
        guard let row = table.clickedRowIfValid, row < entries.count else { return }
        actions.activate(entries[row])
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < entries.count else { return nil }
        let entry = entries[row]
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? Self.makeCell(id, icon: id.rawValue == "name")
        cell.textField?.font = Typography.body
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = entry.name
            cell.imageView?.image = icons.icon(for: entry)
            cell.alphaValue = entry.isHidden ? 0.55 : 1
        case "modified":
            cell.textField?.stringValue = dateFormatter.string(from: entry.modified)
        case "size":
            cell.textField?.stringValue = entry.kind == .file
                ? ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file) : "--"
        default:
            cell.textField?.stringValue = icons.kind(for: entry)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let names = Set(table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].name : nil })
        let cursorRow = table.selectedRow
        actions.select(names, cursorRow >= 0 && cursorRow < entries.count ? entries[cursorRow].name : nil)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = tableView.sortDescriptors.first, let key = first.key else { return }
        let field = FileSortOrder.Field(rawValue: key) ?? .name
        actions.sort(FileSortOrder(field: field, ascending: first.ascending))
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < entries.count else { return nil }
        return entries[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on, row < entries.count, entries[row].kind == .folder { return Self.operation(info) }
        tableView.setDropRow(-1, dropOperation: .on)
        return Self.operation(info)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = FilePasteboard.fileURLs(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        let target = dropOperation == .on && row >= 0 && row < entries.count && entries[row].kind == .folder ? entries[row].url : nil
        let flags = NSEvent.modifierFlags
        actions.drop(urls, target, flags.contains(.option), flags.contains(.command))
        return true
    }

    private static func operation(_ info: any NSDraggingInfo) -> NSDragOperation {
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { return .copy }
        if flags.contains(.command) { return .move }
        return info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier, icon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.font = Typography.body
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        var constraints = [field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                           field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2)]
        if icon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            constraints += [image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                            image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6)]
        } else {
            field.textColor = .secondaryLabelColor
            constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}
