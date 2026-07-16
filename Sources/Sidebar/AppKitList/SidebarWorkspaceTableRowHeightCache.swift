import AppKit
import Foundation
import SwiftUI

/// Stores exact hosted-row heights without measuring from AppKit's layout callbacks.
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
    private let prototypeView = NSHostingView(rootView: AnyView(EmptyView()))
    private var preparedColumnWidth: CGFloat?

    func prepareHostedRows(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat,
        measurableRange: Range<Int>
    ) -> IndexSet {
        prepare(
            rows: rows,
            columnWidth: columnWidth,
            measurableRange: measurableRange,
            measure: measureHostedRow
        )
    }

    /// Cheap per-scroll entry point: prepares only when the column width
    /// changed or a visible row lacks a valid measurement, so steady-state
    /// scrolling inside measured territory costs O(visible) cache probes.
    func prepareHostedRowsForViewportChange(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat,
        measurableRange: Range<Int>,
        visibleRange: Range<Int>
    ) -> IndexSet? {
        guard columnWidth > 0 else { return nil }
        if preparedColumnWidth == columnWidth {
            let needsMeasurement = visibleRange.contains { index in
                guard rows.indices.contains(index) else { return false }
                let row = rows[index]
                guard let entry = entries[row.id],
                      entry.matches(row: row, columnWidth: columnWidth) else {
                    return true
                }
                return false
            }
            guard needsMeasurement else { return nil }
        }
        return prepareHostedRows(
            rows,
            columnWidth: columnWidth,
            measurableRange: measurableRange
        )
    }

    /// Refreshes measurements for rows inside `measurableRange` and carries
    /// forward still-valid measurements everywhere else. Rows outside the
    /// range whose cached measurement went stale fall back to their estimated
    /// height until they approach the viewport, so one width change or bulk
    /// content update never measures the whole list (the historical
    /// all-rows-realized livelock ingredient). Call from render updates or
    /// viewport notifications, never from `heightOfRow`.
    func prepare(
        rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat,
        measurableRange: Range<Int>,
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

            // The table currently displays the stale measurement if one
            // exists, and the estimate otherwise.
            let displayedHeight = previous?.height ?? row.estimatedHeight
            if measurableRange.contains(index) {
                let measuredHeight = Self.normalizedHeight(measure(row, columnWidth))
                if displayedHeight != measuredHeight {
                    changedHeights.insert(index)
                }
                nextEntries[row.id] = Entry(
                    row: row,
                    columnWidth: columnWidth,
                    height: measuredHeight
                )
            } else {
                // Stale and out of measurement range: drop the entry so
                // `height(for:)` falls back to the estimate.
                if displayedHeight != row.estimatedHeight {
                    changedHeights.insert(index)
                }
            }
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

    private func measureHostedRow(
        row: SidebarWorkspaceTableRowConfiguration,
        columnWidth: CGFloat
    ) -> CGFloat {
        let contextMenuActions = SidebarWorkspaceTableContextMenuActions(
            didOpen: {},
            didClose: {}
        )
        prototypeView.rootView = AnyView(
            row.makeContent(false, contextMenuActions)
                .frame(width: columnWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        )
        prototypeView.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 1)
        prototypeView.layoutSubtreeIfNeeded()
        return prototypeView.fittingSize.height
    }
}
