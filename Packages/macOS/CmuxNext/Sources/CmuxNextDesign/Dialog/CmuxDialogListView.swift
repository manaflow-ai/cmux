import AppKit
import CmuxNextDesignTokens

/// A bounded viewport that creates and reuses cells as the list scrolls.
final class CmuxDialogListView: OverlayScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table: NSTableView
    private let rows: [CmuxDialogListRow]
    private let makeLabels: () -> (ThemedLabel, ThemedLabel)?
    private static let cellID = NSUserInterfaceItemIdentifier("cmux.dialog.listRow")

    init(rows: [CmuxDialogListRow], width: CGFloat, makeLabel: @escaping (CmuxDialogView.TextRole, CGFloat) -> ThemedLabel?) {
        self.rows = rows
        let textWidth = width - Metrics.space4
        makeLabels = {
            guard let title = makeLabel(.primary, textWidth), let detail = makeLabel(.secondary, textWidth) else { return nil }
            return (title, detail)
        }
        table = NSTableView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.width = width
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: Metrics.space1)
        let layout = NSLayoutManager()
        table.rowHeight = ceil(layout.defaultLineHeight(for: Typography.cardBody))
            + ceil(layout.defaultLineHeight(for: Typography.cardCaption)) + Metrics.space2
        table.dataSource = self
        table.delegate = self

        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = table
        let pitch = table.rowHeight + table.intercellSpacing.height
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: min(CGFloat(rows.count), 3.5) * pitch),
        ])
        table.noteNumberOfRowsChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: CmuxDialogListCell
        if let reusable = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? CmuxDialogListCell {
            cell = reusable
        } else {
            guard let (title, detail) = makeLabels() else { return nil }
            cell = CmuxDialogListCell(title: title, detail: detail)
            cell.identifier = Self.cellID
        }
        cell.show(rows[row])
        return cell
    }
}

private final class CmuxDialogListCell: NSTableCellView {
    private let title: ThemedLabel
    private let detail: ThemedLabel

    init(title: ThemedLabel, detail: ThemedLabel) {
        self.title = title
        self.detail = detail
        super.init(frame: .zero)

        for label in [title, detail] {
            label.maximumNumberOfLines = 1
        }
        title.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.space1),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ row: CmuxDialogListRow) {
        title.stringValue = row.title.components(separatedBy: .newlines).joined(separator: " ")
        title.themedToolTip = row.title
        detail.stringValue = row.detail.components(separatedBy: .newlines).joined(separator: " ")
        detail.themedToolTip = row.detail
    }
}
