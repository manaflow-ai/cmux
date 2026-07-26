import SwiftUI

/// Isolated SwiftUI graph hosted by one recycled Vault table cell.
struct SessionIndexTableCellRootView: View {
    let row: SessionIndexTableRow
    let environment: SessionIndexTableEnvironmentSnapshot

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
                previewEntryId,
                isCollapsed,
                isPopoverOpen,
                actions,
                setCollapsed,
                setPopoverOpen
            ):
                IndexSectionView(
                    section: section,
                    rowLimit: rowLimit,
                    isDragged: isDragged,
                    previewEntryId: previewEntryId,
                    isCollapsed: Binding(
                        get: { isCollapsed },
                        set: setCollapsed
                    ),
                    isPopoverOpen: Binding(
                        get: { isPopoverOpen },
                        set: setPopoverOpen
                    ),
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
