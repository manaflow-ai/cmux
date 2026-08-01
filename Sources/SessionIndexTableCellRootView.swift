import SwiftUI

/// Cell-local visual state that can repaint selection without replacing the
/// recycled cell's hosted root or owning the popover lifecycle.
@MainActor
final class SessionIndexTableCellPresentationModel: ObservableObject {
    @Published private(set) var previewEntryId: SessionEntry.ID?

    func update(from row: SessionIndexTableRow) {
        let nextPreviewEntryId: SessionEntry.ID?
        switch row {
        case let .section(section, _, _, previewEntryId, _, _, _, _, _):
            nextPreviewEntryId = SessionIndexTableRow.containedPreviewEntryID(
                previewEntryId,
                in: section
            )
        case .gap:
            nextPreviewEntryId = nil
        }
        guard previewEntryId != nextPreviewEntryId else { return }
        previewEntryId = nextPreviewEntryId
    }
}

/// Isolated SwiftUI graph hosted by one recycled Vault table cell.
struct SessionIndexTableCellRootView: View {
    let row: SessionIndexTableRow
    let environment: SessionIndexTableEnvironmentSnapshot
    @ObservedObject var presentation: SessionIndexTableCellPresentationModel

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
                _,
                actions,
                setCollapsed,
                setPopoverOpen
            ):
                IndexSectionView(
                    section: section,
                    rowLimit: rowLimit,
                    isDragged: isDragged,
                    previewEntryId: presentation.previewEntryId,
                    isCollapsed: Binding(
                        get: { isCollapsed },
                        set: setCollapsed
                    ),
                    onShowMore: { setPopoverOpen(true) },
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
