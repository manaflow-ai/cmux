import AppKit

/// The list layout's table: hands keys it does not use to the pane
/// (type-select, Files shortcuts) and asks the pane for context menus.
final class FileTableView: NSTableView {
    /// Gets keys before the table's own handling; true when used.
    var keyHandler: ((NSEvent) -> Bool)?
    /// The context menu for a row (-1: the background).
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(row)
    }
}
