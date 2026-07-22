/// Immutable row configuration consumed by the AppKit-owned Vault table.
enum SessionIndexTableRow {
    case section(
        section: IndexSection,
        rowLimit: Int,
        isDragged: Bool,
        previewEntryId: SessionEntry.ID?,
        isCollapsed: Bool,
        isPopoverOpen: Bool,
        actions: IndexSectionActions,
        setCollapsed: @MainActor (Bool) -> Void,
        setPopoverOpen: @MainActor (Bool) -> Void
    )
    case gap(
        beforeKey: SectionKey?,
        isValidDrop: Bool,
        actions: SectionGapActions
    )

    var id: SessionIndexTableRowID {
        switch self {
        case .section(let section, _, _, _, _, _, _, _, _):
            return .section(section.key)
        case .gap(let beforeKey?, _, _):
            return .gapBefore(beforeKey)
        case .gap(nil, _, _):
            return .trailingGap
        }
    }

    func hasEquivalentContent(to other: SessionIndexTableRow) -> Bool {
        switch (self, other) {
        case let (
            .section(lhsSection, lhsLimit, lhsDragged, lhsPreview, lhsCollapsed, lhsPopover, _, _, _),
            .section(rhsSection, rhsLimit, rhsDragged, rhsPreview, rhsCollapsed, rhsPopover, _, _, _)
        ):
            return lhsSection == rhsSection
                && lhsLimit == rhsLimit
                && lhsDragged == rhsDragged
                && lhsPreview == rhsPreview
                && lhsCollapsed == rhsCollapsed
                && lhsPopover == rhsPopover
        case let (.gap(lhsKey, lhsValid, _), .gap(rhsKey, rhsValid, _)):
            return lhsKey == rhsKey && lhsValid == rhsValid
        default:
            return false
        }
    }
}
