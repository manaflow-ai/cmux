import AppKit
import Foundation

/// Stores exact native-row heights without measuring from AppKit layout callbacks.
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

    func suspendPresentation(retaining rowIds: Set<SidebarWorkspaceRenderItemID>) {
        entries = entries.reduce(
            into: [SidebarWorkspaceRenderItemID: Entry]()
        ) { suspendedEntries, pair in
            guard rowIds.contains(pair.key) else { return }
            suspendedEntries[pair.key] = Entry(
                row: pair.value.row.presentationSnapshot(),
                columnWidth: pair.value.columnWidth,
                height: pair.value.height
            )
        }
        preparedColumnWidth = nil
        prototypeRowView.suspendPresentation()
    }

    func prepareNativeRows(
        _ rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat,
        skippingEquivalenceCheckAt unchanged: IndexSet = []
    ) -> IndexSet {
        return prepare(
            rows: rows,
            columnWidth: columnWidth,
            skippingEquivalenceCheckAt: unchanged,
            measure: measureNativeRow
        )
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
    ///
    /// `skippingEquivalenceCheckAt`: indices the caller already proved
    /// content-equivalent to the previous apply (the controller's reconfigure
    /// diff). Their entries carry over without re-running the row equality
    /// check here, so one apply performs a single equivalence pass instead
    /// of two. Only valid when the row at that index kept its id, which the
    /// controller guarantees by passing it only on non-structural applies.
    func prepare(
        rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat,
        skippingEquivalenceCheckAt unchanged: IndexSet = [],
        measure: Measurement
    ) -> IndexSet {
        guard columnWidth > 0 else {
            entries.removeAll(keepingCapacity: true)
            preparedColumnWidth = nil
            return []
        }
        let widthUnchanged = preparedColumnWidth == columnWidth
        preparedColumnWidth = columnWidth

        var nextEntries: [SidebarWorkspaceRenderItemID: Entry] = [:]
        nextEntries.reserveCapacity(rows.count)
        var changedHeights = IndexSet()

        for (index, row) in rows.enumerated() {
            let previous = entries[row.id]
            if widthUnchanged, unchanged.contains(index), let previous {
                nextEntries[row.id] = previous
                continue
            }
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

    /// Live-resize partial pass: re-measures only `indexes` at the live
    /// width, leaving every other entry at its previous width. Only the
    /// deterministic native rows re-measure here. Returns the indexes whose
    /// height changed.
    func prepareRows(
        at indexes: IndexSet,
        in rows: [SidebarWorkspaceTableRowConfiguration],
        columnWidth: CGFloat
    ) -> IndexSet {
        guard columnWidth > 0 else { return [] }
        var changedHeights = IndexSet()
        for index in indexes {
            guard rows.indices.contains(index) else { continue }
            let row = rows[index]
            guard row.appKitGroupHeaderModel != nil || row.appKitWorkspaceRowModel != nil else { continue }
            let previous = entries[row.id]
            if let previous, previous.matches(row: row, columnWidth: columnWidth) { continue }
            let measuredHeight = Self.normalizedHeight(measureNativeRow(row: row, columnWidth: columnWidth))
            if (previous?.height ?? row.estimatedHeight) != measuredHeight {
                changedHeights.insert(index)
            }
            entries[row.id] = Entry(
                row: row,
                columnWidth: columnWidth,
                height: measuredHeight
            )
        }
        return changedHeights
    }

    /// A pure cache read used by `tableView(_:heightOfRow:)` during layout.
    func height(
        for row: SidebarWorkspaceTableRowConfiguration,
        columnWidth: CGFloat
    ) -> CGFloat? {
        guard let entry = entries[row.id] else { return nil }
        if entry.matches(row: row, columnWidth: columnWidth) { return entry.height }
        // Mid-live-resize, visible rows carry entries at the live width while
        // the lookup still uses the last settled width; a content-matched
        // entry at another width is that fresher measurement, and the settle
        // pass re-measures every width-mismatched entry afterward.
        guard entry.row.hasEquivalentContent(to: row) else { return nil }
        return entry.height
    }

    private static func normalizedHeight(_ height: CGFloat) -> CGFloat {
        ceil(max(1, height))
    }

    private func measureNativeRow(
        row: SidebarWorkspaceTableRowConfiguration,
        columnWidth: CGFloat
    ) -> CGFloat {
        // Native rows have deterministic heights.
        if let headerModel = row.appKitGroupHeaderModel {
            return SidebarGroupHeaderTableCellView.preferredHeight(model: headerModel)
        }
        if let rowModel = row.appKitWorkspaceRowModel,
           let actions = row.appKitWorkspaceRowActions {
            defer { prototypeRowView.suspendPresentation() }
            prototypeRowView.configure(
                model: rowModel,
                actions: actions,
                isPointerHovering: false,
                contextMenuDidOpen: {},
                contextMenuDidClose: {}
            )
            return prototypeRowView.layoutContent(model: rowModel, width: columnWidth, apply: false)
        }
        return row.measuredFallbackHeight ?? row.estimatedHeight
    }
}
