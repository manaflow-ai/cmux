import AppKit

/// The transcript table: one column, no selection, no header, transparent background.
final class AcpmuxTranscriptTableView: NSTableView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("acpmuxChat.column"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        headerView = nil
        intercellSpacing = .zero
        backgroundColor = .clear
        selectionHighlightStyle = .none
        allowsEmptySelection = true
        allowsColumnSelection = false
        usesAutomaticRowHeights = false
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        gridStyleMask = []
        focusRingType = .none
        style = .plain
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Rows are not selectable; keep keyboard focus on the composer.
    override var acceptsFirstResponder: Bool { false }
}
