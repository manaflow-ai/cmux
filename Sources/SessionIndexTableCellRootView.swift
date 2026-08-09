import Observation
import SwiftUI

/// Derived cell-local highlight projection. The table row remains authoritative;
/// this object can only repaint selection without replacing the hosted root.
@MainActor
@Observable
final class SessionIndexTableCellHighlightProjection {
    private(set) var previewEntryID: SessionEntry.ID?

    func sync(from row: SessionIndexTableRow) {
        let nextPreviewEntryID = row.containedPreviewEntryID
        guard previewEntryID != nextPreviewEntryID else { return }
        previewEntryID = nextPreviewEntryID
    }
}

/// Isolated SwiftUI graph hosted by one recycled Vault table cell.
struct SessionIndexTableCellRootView: View {
    let row: SessionIndexTableRow
    let environment: SessionIndexTableEnvironmentSnapshot
    let highlight: SessionIndexTableCellHighlightProjection
    let onPopoverAnchorChange: (SessionIndexTablePopoverIdentity, CGRect?) -> Void

    var body: some View {
        environment.apply(to: rowContent)
    }

    @ViewBuilder
    private var rowContent: some View {
        Group {
            switch row {
            case let .section(
                section,
                rowLimit,
                isDragged,
                _,
                isCollapsed,
                actions,
                setCollapsed,
                setPopoverOpen
            ):
                IndexSectionView(
                    section: section,
                    rowLimit: rowLimit,
                    isDragged: isDragged,
                    previewEntryId: highlight.previewEntryID,
                    isCollapsed: Binding(
                        get: { isCollapsed },
                        set: setCollapsed
                    ),
                    onShowMore: { setPopoverOpen(true) },
                    onPopoverAnchorChange: onPopoverAnchorChange,
                    actions: actions
                )
                .equatable()
            case let .gap(beforeKey, isValidDrop, actions):
                SectionReorderGap(
                    beforeKey: beforeKey,
                    isValidDrop: isValidDrop,
                    actions: actions
                )
                .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
