import AppKit
import Foundation

/// Stores exact native-row heights without measuring from AppKit's layout callbacks.
@MainActor
final class SidebarWorkspaceTableRowHeightCache {
    typealias Measurement = (
        _ row: SidebarWorkspaceTableRowConfiguration,
        _ columnWidth: CGFloat
    ) -> CGFloat

    @MainActor
    private struct Entry {
        let row: SidebarWorkspaceTableRowConfiguration
        let columnWidth: CGFloat
        let height: CGFloat

        func matches(
            row candidate: SidebarWorkspaceTableRowConfiguration,
            columnWidth candidateWidth: CGFloat
        ) -> Bool {
            columnWidth == candidateWidth && row.hasEquivalentContent(to: candidate)
        }
    }

    private var entries: [SidebarWorkspaceRenderItemID: Entry] = [:]
    private let prototypeRowView = SidebarWorkspaceRowTableCellView()
    private var preparedColumnWidth: CGFloat?

    func prepareNativeRows(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat
    ) -> IndexSet {
        prepare(rows: rows, columnWidth: columnWidth, measure: measureNativeRow)
    }

    func prepareNativeRowsIfWidthChanged(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat
    ) -> IndexSet? {
        guard columnWidth > 0, preparedColumnWidth != columnWidth else { return nil }
        return prepareNativeRows(rows, columnWidth: columnWidth)
    }

    /// Measures only missing or invalid entries. Call from render updates or
    /// viewport-width notifications, never from `heightOfRow`.
    func prepare(
        rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat,
        measure: Measurement
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
            if let previous, previous.matches(row: row, columnWidth: columnWidth) {
                nextEntries[row.id] = previous
                continue
            }

            let measuredHeight = Self.normalizedHeight(measure(row, columnWidth))
            let previousHeight = previous?.height ?? row.estimatedHeight
            if previousHeight != measuredHeight {
                changedHeights.insert(index)
            }
            nextEntries[row.id] = Entry(
                row: row,
                columnWidth: columnWidth,
                height: measuredHeight
            )
        }

        entries = nextEntries
        return changedHeights
    }

    /// A pure cache read used by `tableView(_:heightOfRow:)` during layout.
    func height(
        for row: SidebarWorkspaceTableRowConfiguration,
        columnWidth: CGFloat
    ) -> CGFloat? {
        guard let entry = entries[row.id],
              entry.matches(row: row, columnWidth: columnWidth) else {
            return nil
        }
        return entry.height
    }

    private static func normalizedHeight(_ height: CGFloat) -> CGFloat {
        ceil(max(1, height))
    }

    private func measureNativeRow(
        row: SidebarWorkspaceTableRowConfiguration,
        columnWidth: CGFloat
    ) -> CGFloat {
        if let headerModel = row.appKitGroupHeaderModel {
            return SidebarGroupHeaderTableCellView.preferredHeight(model: headerModel)
        }
        if let rowModel = row.appKitWorkspaceRowModel,
           let actions = row.appKitWorkspaceRowActions {
            prototypeRowView.configure(
                model: rowModel,
                actions: actions,
                isPointerHovering: false,
                contextMenuDidOpen: {},
                contextMenuDidClose: {}
            )
            return prototypeRowView.layoutContent(model: rowModel, width: columnWidth, apply: false)
        }
        assertionFailure("Sidebar table row \(row.id) has no native cell model")
        return row.estimatedHeight
    }
}
