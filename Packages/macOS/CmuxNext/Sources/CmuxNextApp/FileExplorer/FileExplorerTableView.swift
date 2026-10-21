import AppKit

/// The file explorer's list. Return and Cmd-Down open the selection through
/// the registry (`fileExplorerOpenSelection`, `…FinderAlias`): bare keys
/// never reach the key router's binding table, so the list sends them itself.
/// Its first responder state is what publishes `fileExplorerFocused`.
final class FileExplorerTableView: NSTableView {
    /// Runs an explorer action on this list's selection.
    var perform: (@MainActor (String) -> Void)?
    /// The rows of the right-click menu, made for the clicked row.
    var contextMenu: (@MainActor () -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (36, []), (76, []): perform?("fileExplorerOpenSelection")
        case (125, [.command]), (125, [.command, .numericPad, .function]), (125, [.command, .function]):
            perform?("fileExplorerOpenSelectionFinderAlias")
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return row >= 0 ? contextMenu?() : nil
    }
}
