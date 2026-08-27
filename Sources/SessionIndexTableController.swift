import AppKit
import CmuxAppKitSupportUI

/// Main-actor owner of the Vault table lifecycle and its immutable row snapshot.
@MainActor
final class SessionIndexTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("vault-session")
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("vault-session-cell")

    /// Keeps the toggled section's top edge stable while AppKit recalculates
    /// its row height. Without an anchor, NSTableView may preserve the bottom
    /// edge of the document and make an expansion appear to grow upward.
    @MainActor
    private struct ViewportAnchor {
        let rowID: SessionIndexTableRowID
        let offsetFromViewportTop: CGFloat

        static func capture(
            table: NSTableView,
            rows: [SessionIndexTableRow],
            preferredRows: IndexSet
        ) -> Self? {
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return nil }

            let preferredIndex = preferredRows.first {
                NSLocationInRange($0, visible)
            }
            let rowIndex = preferredIndex ?? visible.location
            guard rows.indices.contains(rowIndex) else { return nil }

            return Self(
                rowID: rows[rowIndex].id,
                offsetFromViewportTop: table.rect(ofRow: rowIndex).minY - table.visibleRect.minY
            )
        }

        func restore(table: NSTableView, rows: [SessionIndexTableRow]) {
            guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }),
                  let scrollView = table.enclosingScrollView else {
                return
            }
            table.layoutSubtreeIfNeeded()
            let clipView = scrollView.contentView
            var bounds = clipView.bounds
            let targetOriginY = table.rect(ofRow: rowIndex).minY - offsetFromViewportTop
            guard abs(targetOriginY - bounds.origin.y) > 0.5 else { return }
            bounds.origin.y = targetOriginY
            clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private weak var containerView: SessionIndexTableContainerView?
    private var rows: [SessionIndexTableRow] = []
    /// The table owns disclosure state so a click can commit one row snapshot
    /// without waiting for the outer SwiftUI graph to rebuild.
    private var collapsedSectionKeys: Set<SectionKey> = []
    private var environment: SessionIndexTableEnvironmentSnapshot?
    private let rowHeightCalculator = SessionIndexTableRowHeightCalculator()
    private let popoverPresenter: SessionIndexTablePopoverPresenter
    private var scrollBoundsObserver: NSObjectProtocol?
    private var isApplyingRows = false
    private lazy var mutationScheduler = SessionIndexTableMutationScheduler(
        applyFlush: { [weak self] in self?.flushApply($0) }
    )

    init(popoverPresenter: SessionIndexTablePopoverPresenter? = nil) {
        self.popoverPresenter = popoverPresenter ?? SessionIndexTablePopoverPresenter()
        super.init()
    }

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
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self, weak table] _ in
            guard let self, let table, !self.isApplyingRows else { return }
            self.reconcilePresentation(in: table)
        }
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

    /// Projects incoming rows onto the controller-owned disclosure snapshot.
    /// The parent may rebuild rows for unrelated Vault changes, but it cannot
    /// accidentally reset an in-progress disclosure transition.
    private func canonicalRows(from inputRows: [SessionIndexTableRow]) -> [SessionIndexTableRow] {
        var availableSections = Set<SectionKey>()
        let projected = inputRows.map { row -> SessionIndexTableRow in
            guard case let .section(
                section,
                rowLimit,
                isDragged,
                popoverIdentity,
                _,
                actions,
                parentSetCollapsed,
                setPopoverOpen
            ) = row else {
                return row
            }

            availableSections.insert(section.key)
            let sectionKey = section.key
            let isCollapsed = collapsedSectionKeys.contains(sectionKey)
            // A stale parent snapshot can still carry the popover identity
            // for the click that just collapsed this section. Clear it in the
            // same canonical projection so the table never paints a hidden
            // anchor for one frame while SwiftUI catches up.
            let effectivePopoverIdentity = isCollapsed ? nil : popoverIdentity
            return .section(
                section: section,
                rowLimit: rowLimit,
                isDragged: isDragged,
                popoverIdentity: effectivePopoverIdentity,
                isCollapsed: isCollapsed,
                actions: actions,
                setCollapsed: { [weak self] value in
                    self?.setCollapsed(
                        sectionKey: sectionKey,
                        value: value,
                        parentAction: parentSetCollapsed
                    )
                },
                setPopoverOpen: setPopoverOpen
            )
        }
        collapsedSectionKeys.formIntersection(availableSections)
        return projected
    }

    /// Commits a disclosure mutation directly through the table controller.
    /// The outer SwiftUI projection will converge to this snapshot afterward,
    /// but it cannot create a second visible transition.
    private func setCollapsed(
        sectionKey: SectionKey,
        value: Bool,
        parentAction: @escaping @MainActor (Bool) -> Void
    ) {
        guard !isApplyingRows,
              collapsedSectionKeys.contains(sectionKey) != value else {
            return
        }

        collapsedSectionKeys.remove(sectionKey)
        if value {
            collapsedSectionKeys.insert(sectionKey)
        }

        // Preserve the existing popover-dismissal contract without letting
        // that parent state change own the table transition.
        parentAction(value)
        mutationScheduler.cancelPending()

        guard let environment else { return }
        let nextRows = canonicalRows(from: rows)
        flushApply(
            SessionIndexTableApplyInput(
                rows: nextRows,
                environment: environment
            )
        )
    }

    func dismantle() {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
            self.scrollBoundsObserver = nil
        }
        popoverPresenter.dismiss()
    }

    private func flushApply(_ input: SessionIndexTableApplyInput) {
        guard let table = containerView?.tableView else { return }
        let nextRows = canonicalRows(from: input.rows)
        let nextEnvironment = input.environment
        let previousRows = rows
        let hasStructuralChanges = previousRows.map(\.id) != nextRows.map(\.id)
        let hasEnvironmentChanges = environment?.hasEquivalentPresentation(
            to: nextEnvironment
        ) != true
        rows = nextRows
        environment = nextEnvironment
        isApplyingRows = true
        defer {
            isApplyingRows = false
            refreshVisibleCellPresentations(in: table)
            reconcilePresentation(in: table)
        }

        if hasStructuralChanges || hasEnvironmentChanges {
            table.reloadData()
            return
        }

        let changedRows = IndexSet(nextRows.indices.filter { index in
            !previousRows[index].hasEquivalentContent(to: nextRows[index])
        })
        guard !changedRows.isEmpty else { return }
        let viewportAnchor = ViewportAnchor.capture(
            table: table,
            rows: previousRows,
            preferredRows: changedRows
        )
        reconfigureVisibleCells(table, indexes: changedRows)
        noteHeightOfRowsWithoutAnimation(table, changedRows)
        viewportAnchor?.restore(table: table, rows: nextRows)
    }

    /// Reconfigures realized cells in place so a disclosure toggle does not
    /// tear down and recreate the hosting view. Offscreen rows are picked up
    /// by `viewFor` when AppKit realizes them later.
    private func reconfigureVisibleCells(
        _ table: NSTableView,
        indexes: IndexSet
    ) {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0,
              let environment else { return }

        for rowIndex in indexes where NSLocationInRange(rowIndex, visible) {
            guard rows.indices.contains(rowIndex),
                  let cell = table.view(
                      atColumn: 0,
                      row: rowIndex,
                      makeIfNecessary: false
                  ) as? SessionIndexTableCellView else {
                continue
            }
            cell.configure(row: rows[rowIndex], environment: environment)
        }
    }

    /// NSTableView animates `noteHeightOfRows` by default. Vault rows are
    /// hosted inside a virtualized table, so that implicit animation can move
    /// the clip origin and make a section appear to expand upward. The table
    /// still updates its height synchronously; only the unwanted interpolation
    /// is suppressed.
    private func noteHeightOfRowsWithoutAnimation(
        _ table: NSTableView,
        _ indexes: IndexSet
    ) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        table.noteHeightOfRows(withIndexesChanged: indexes)
        NSAnimationContext.endGrouping()
    }

    private func refreshVisibleCellPresentations(in table: NSTableView) {
        let visibleRows = table.rows(in: table.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let visibleIndexes = visibleRows.location..<NSMaxRange(visibleRows)
        for rowIndex in visibleIndexes where rows.indices.contains(rowIndex) {
            (table.view(
                atColumn: 0,
                row: rowIndex,
                makeIfNecessary: false
            ) as? SessionIndexTableCellView)?.updatePresentation(from: rows[rowIndex])
        }
    }

    private func reconcilePresentation(in table: NSTableView) {
        guard let presentation = rows.lazy.compactMap(\.popoverPresentation).first else {
            popoverPresenter.dismiss()
            return
        }
        guard let rowIndex = rows.firstIndex(where: {
            $0.id == .section(presentation.identity.sectionKey)
        }) else {
            popoverPresenter.dismiss()
            return
        }
        guard let cell = table.view(
            atColumn: 0,
            row: rowIndex,
            makeIfNecessary: false
        ) as? SessionIndexTableCellView else {
            return
        }
        guard let anchorRectInCell = cell.popoverAnchorRect(for: presentation.identity) else {
            return
        }
        // Section cells host the entire group, while the selected session may
        // be many rows below its top edge. Use the table (a visible, flipped
        // positioning view) and convert the row-local rectangle into table
        // coordinates. Anchoring directly to the tall recycled cell makes
        // AppKit see an offscreen positioning rect and fall back to centering
        // the popover, which disconnects the transcript from its row.
        let anchorRect = cell.convert(anchorRectInCell, to: table)
        // NSTableView reports recycling through the row view itself. Retain
        // that exact owner so `didRemove` can dismiss deterministically even
        // after AppKit has detached the cell from its hierarchy.
        let anchorOwnerView = cell.superview ?? cell
        popoverPresenter.reconcile(
            presentation,
            relativeTo: anchorRect,
            of: table,
            ownedBy: anchorOwnerView
        )
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
        cell.onPopoverAnchorChange = { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            guard !self.isApplyingRows else { return }
            self.reconcilePresentation(in: tableView)
        }
        cell.configure(
            row: rows[row],
            environment: environment ?? .fallback
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard !isApplyingRows else { return }
        reconcilePresentation(in: tableView)
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard popoverPresenter.isAnchored(in: rowView) else { return }
        if isApplyingRows {
            popoverPresenter.dismiss()
        } else {
            popoverPresenter.dismissAndNotify()
        }
    }
}
