package import AppKit

/// The file explorer's list. Return and Cmd-Down open the selection through
/// the registry (`fileExplorerOpenSelection`, `…FinderAlias`): bare keys
/// never reach the key router's binding table, so the list sends them itself.
/// Its first responder state is what publishes `fileExplorerFocused`.
package final class FileExplorerTableView: NSTableView {
    /// Runs an explorer action on this list's selection.
    package var perform: (@MainActor (String) -> Void)?
    /// The rows of the right-click menu, made for the clicked row.
    package var contextMenu: (@MainActor () -> NSMenu?)?

    package override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (36, []), (76, []): perform?("fileExplorerOpenSelection")
        case (125, [.command]), (125, [.command, .numericPad, .function]), (125, [.command, .function]):
            perform?("fileExplorerOpenSelectionFinderAlias")
        case (51, [.command]): perform?("fileExplorerMoveToTrash") // Cmd-Delete, as in Finder
        default: super.keyDown(with: event)
        }
    }

    package override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        // The empty area: no selection, so the menu offers New File and New Folder in the root.
        if row < 0 { deselectAll(nil) }
        return contextMenu?()
    }
}
