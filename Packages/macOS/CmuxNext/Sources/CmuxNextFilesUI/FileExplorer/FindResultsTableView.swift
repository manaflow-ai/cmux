package import AppKit

/// The Find results list: Return opens the selected result (bare keys never
/// reach the key router's binding table, so the list handles it).
package final class FindResultsTableView: NSTableView {
    package var open: (@MainActor () -> Void)?
    package var contextMenu: (@MainActor () -> NSMenu?)?

    package override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            open?()
        } else {
            super.keyDown(with: event)
        }
    }

    package override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return contextMenu?()
    }
}
