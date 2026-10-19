import Observation
import SwiftUI

/// Cell-owned immutable-snapshot projection for one recycled Vault row.
///
/// The AppKit table keeps the hosting root alive while this model changes. That
/// ordering matters for disclosure: replacing `NSHostingView.rootView` at the
/// same time as `NSTableView` changes a row height can expose a blank frame for
/// one layout pass, which reads as a flicker.
@MainActor
@Observable
final class SessionIndexTableCellModel {
    private(set) var row: SessionIndexTableRow
    private(set) var environment: SessionIndexTableEnvironmentSnapshot

    init(
        row: SessionIndexTableRow,
        environment: SessionIndexTableEnvironmentSnapshot
    ) {
        self.row = row
        self.environment = environment
    }

    @discardableResult
    func configure(
        row: SessionIndexTableRow,
        environment: SessionIndexTableEnvironmentSnapshot
    ) -> Bool {
        guard !self.row.hasEquivalentContent(to: row)
                || !self.environment.hasEquivalentPresentation(to: environment) else {
            return false
        }
        self.row = row
        self.environment = environment
        return true
    }
}

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
@MainActor
struct SessionIndexTableCellRootView: View {
    let model: SessionIndexTableCellModel
    let highlight: SessionIndexTableCellHighlightProjection
    let onPopoverAnchorChange: (SessionIndexTablePopoverIdentity, CGRect?) -> Void

    var body: some View {
        model.environment.apply(to: rowContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var rowContent: some View {
        Group {
            switch model.row {
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
                    isCollapsed: isCollapsed,
                    onToggleCollapsed: { setCollapsed(!isCollapsed) },
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
