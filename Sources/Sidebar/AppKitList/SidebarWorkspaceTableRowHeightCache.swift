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
    private let prototypeRowView = SidebarWorkspaceRowTableCellView()
    private var preparedColumnWidth: CGFloat?

    func prepareHostedRows(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat
    ) -> IndexSet {
        return prepare(rows: rows, columnWidth: columnWidth, measure: measureHostedRow)
    }

    func prepareHostedRowsIfWidthChanged(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat
    ) -> IndexSet? {
        guard columnWidth > 0, preparedColumnWidth != columnWidth else { return nil }
        return prepareHostedRows(rows, columnWidth: columnWidth)
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

    private func measureHostedRow(
        row: SidebarWorkspaceTableRowConfiguration,
        columnWidth: CGFloat
    ) -> CGFloat {
        // Pure-AppKit rows have deterministic heights; never spin up the
        // hosted SwiftUI measurement path for them.
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
