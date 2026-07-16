import AppKit
import Foundation

/// Measures a configured row's exact height at a pinned width.
@MainActor
protocol SidebarWorkspaceListSizingCell: NSView {
    func configureForSizing(
        row: SidebarWorkspaceListRow,
        environment: SidebarWorkspaceListEnvironment
    )
    func fittingHeight(forWidth width: CGFloat) -> CGFloat
}

/// Stores exact row heights measured outside AppKit's layout callbacks.
///
/// Measurement uses off-window prototype cells configured from the same
/// immutable row values the visible cells render, so `heightOfRow` stays a
/// pure cache read during table layout.
@MainActor
final class SidebarWorkspaceTableRowHeightCache {
    private struct Entry {
        let row: SidebarWorkspaceListRow
        let columnWidth: CGFloat
        let environment: SidebarWorkspaceListEnvironment
        let height: CGFloat

        func matches(
            row candidate: SidebarWorkspaceListRow,
            columnWidth candidateWidth: CGFloat,
            environment candidateEnvironment: SidebarWorkspaceListEnvironment
        ) -> Bool {
            columnWidth == candidateWidth
                && environment == candidateEnvironment
                && row == candidate
        }
    }

    private var entries: [SidebarWorkspaceRenderItemID: Entry] = [:]
    private var preparedColumnWidth: CGFloat?
    private var sizingWorkspaceCell: (any SidebarWorkspaceListSizingCell)?
    private var sizingGroupHeaderCell: (any SidebarWorkspaceListSizingCell)?
    private let makeWorkspaceSizingCell: @MainActor () -> any SidebarWorkspaceListSizingCell
    private let makeGroupHeaderSizingCell: @MainActor () -> any SidebarWorkspaceListSizingCell

    init(
        makeWorkspaceSizingCell: @escaping @MainActor () -> any SidebarWorkspaceListSizingCell,
        makeGroupHeaderSizingCell: @escaping @MainActor () -> any SidebarWorkspaceListSizingCell
    ) {
        self.makeWorkspaceSizingCell = makeWorkspaceSizingCell
        self.makeGroupHeaderSizingCell = makeGroupHeaderSizingCell
    }

    /// Measures only missing or invalid entries. Call from render updates or
    /// viewport-width notifications, never from `heightOfRow`.
    func prepare(
        rows: [SidebarWorkspaceListRow],
        columnWidth: CGFloat,
        environment: SidebarWorkspaceListEnvironment
    ) -> IndexSet {
        guard columnWidth > 0 else {
            entries.removeAll(keepingCapacity: true)
            preparedColumnWidth = nil
            return []
        }
        preparedColumnWidth = columnWidth

        var nextEntries: [SidebarWorkspaceRenderItemID: Entry] = [:]
        nextEntries.reserveCapacity(rows.count)
        var changedHeights = IndexSet()

        for (index, row) in rows.enumerated() {
            let previous = entries[row.id]
            if let previous,
               previous.matches(row: row, columnWidth: columnWidth, environment: environment) {
                nextEntries[row.id] = previous
                continue
            }

            let measured = Self.normalizedHeight(
                measure(row: row, columnWidth: columnWidth, environment: environment)
            )
            let previousHeight = previous?.height
                ?? SidebarWorkspaceTableRowHeightCalculator().estimatedHeight(
                    for: row,
                    globalFontMagnificationPercent: environment.globalFontMagnificationPercent
                )
            if previousHeight != measured {
                changedHeights.insert(index)
            }
            nextEntries[row.id] = Entry(
                row: row,
                columnWidth: columnWidth,
                environment: environment,
                height: measured
            )
        }

        entries = nextEntries
        return changedHeights
    }

    /// Drops one row's cached height so the next `prepare` re-measures it even
    /// though its snapshot value is unchanged (cell-local transient state —
    /// metadata show-more, checklist add/edit — changed the rendered height).
    func invalidate(id: SidebarWorkspaceRenderItemID) {
        entries.removeValue(forKey: id)
    }

    func prepareIfWidthChanged(
        rows: [SidebarWorkspaceListRow],
        columnWidth: CGFloat,
        environment: SidebarWorkspaceListEnvironment
    ) -> IndexSet? {
        guard columnWidth > 0, preparedColumnWidth != columnWidth else { return nil }
        return prepare(rows: rows, columnWidth: columnWidth, environment: environment)
    }

    /// A pure cache read used by `tableView(_:heightOfRow:)` during layout.
    func height(
        for row: SidebarWorkspaceListRow,
        columnWidth: CGFloat,
        environment: SidebarWorkspaceListEnvironment
    ) -> CGFloat? {
        guard let entry = entries[row.id],
              entry.matches(row: row, columnWidth: columnWidth, environment: environment) else {
            return nil
        }
        return entry.height
    }

    private static func normalizedHeight(_ height: CGFloat) -> CGFloat {
        ceil(max(1, height))
    }

    private func measure(
        row: SidebarWorkspaceListRow,
        columnWidth: CGFloat,
        environment: SidebarWorkspaceListEnvironment
    ) -> CGFloat {
        let cell: any SidebarWorkspaceListSizingCell
        if row.isGroupHeader {
            if let existing = sizingGroupHeaderCell {
                cell = existing
            } else {
                cell = makeGroupHeaderSizingCell()
                sizingGroupHeaderCell = cell
            }
        } else {
            if let existing = sizingWorkspaceCell {
                cell = existing
            } else {
                cell = makeWorkspaceSizingCell()
                sizingWorkspaceCell = cell
            }
        }
        cell.configureForSizing(row: row, environment: environment)
        return cell.fittingHeight(forWidth: columnWidth)
    }
}
