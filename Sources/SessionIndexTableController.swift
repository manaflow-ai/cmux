import AppKit
import CmuxAppKitSupportUI

/// Main-actor owner of the Vault table lifecycle and its immutable row snapshot.
@MainActor
final class SessionIndexTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("vault-session")
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("vault-session-cell")

    private weak var containerView: SessionIndexTableContainerView?
    private var rows: [SessionIndexTableRow] = []
    private var environment: SessionIndexTableEnvironmentSnapshot?
    private let rowHeightCalculator = SessionIndexTableRowHeightCalculator()
    private lazy var mutationScheduler = SessionIndexTableMutationScheduler(
        applyFlush: { [weak self] in self?.flushApply($0) }
    )

    func makeContainerView() -> SessionIndexTableContainerView {
        let container = SessionIndexTableContainerView()
        containerView = container

        let table = container.tableView
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = false
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.rowHeight = 24
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scrollView = container.scrollView
        scrollView.documentView = table
        table.frame = scrollView.contentView.bounds
        table.autoresizingMask = [.width]
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scrollView.applySidebarOverlayScrollerConfiguration()

        return container
    }

    func apply(
        rows nextRows: [SessionIndexTableRow],
        environment nextEnvironment: SessionIndexTableEnvironmentSnapshot
    ) {
        mutationScheduler.stageApply(
            SessionIndexTableApplyInput(rows: nextRows, environment: nextEnvironment)
        )
    }

    private func flushApply(_ input: SessionIndexTableApplyInput) {
        guard let table = containerView?.tableView else { return }
        let nextRows = input.rows
        let nextEnvironment = input.environment
        let previousRows = rows
        let hasStructuralChanges = previousRows.map(\.id) != nextRows.map(\.id)
        let hasEnvironmentChanges = environment?.hasEquivalentPresentation(
            to: nextEnvironment
        ) != true
        rows = nextRows
        environment = nextEnvironment

        if hasStructuralChanges || hasEnvironmentChanges {
            table.reloadData()
            return
        }

        let changedRows = IndexSet(nextRows.indices.filter { index in
            !previousRows[index].hasEquivalentContent(to: nextRows[index])
        })
        guard !changedRows.isEmpty else { return }
        table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
        table.noteHeightOfRows(withIndexesChanged: changedRows)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return tableView.rowHeight }
        return rowHeightCalculator.height(
            for: rows[row],
            environment: environment ?? .fallback
        )
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? SessionIndexTableCellView) ?? SessionIndexTableCellView()
        cell.identifier = Self.cellIdentifier
        cell.configure(
            row: rows[row],
            environment: environment ?? .fallback
        )
        return cell
    }
}
