/// Immutable row configuration consumed by the AppKit-owned Vault table.
enum SessionIndexTableRow {
    case section(
        section: IndexSection,
        rowLimit: Int,
        isDragged: Bool,
        popoverIdentity: SessionIndexTablePopoverIdentity?,
        isCollapsed: Bool,
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
        case .section(let section, _, _, _, _, _, _, _):
            return .section(section.key)
        case .gap(let beforeKey?, _, _):
            return .gapBefore(beforeKey)
        case .gap(nil, _, _):
            return .trailingGap
        }
    }

    static func containedPreviewEntryID(
        _ candidate: SessionEntry.ID?,
        in section: IndexSection
    ) -> SessionEntry.ID? {
        guard let candidate, section.entries.contains(where: { $0.id == candidate }) else { return nil }
        return candidate
    }

    var containedPreviewEntryID: SessionEntry.ID? {
        guard case let .section(section, _, _, popoverIdentity, _, _, _, _) = self,
              case let .transcript(sectionKey, entryID)? = popoverIdentity,
              sectionKey == section.key else {
            return nil
        }
        return Self.containedPreviewEntryID(entryID, in: section)
    }

    func hasEquivalentContent(to other: SessionIndexTableRow) -> Bool {
        switch (self, other) {
        case let (
            .section(lhsSection, lhsLimit, lhsDragged, _, lhsCollapsed, _, _, _),
            .section(rhsSection, rhsLimit, rhsDragged, _, rhsCollapsed, _, _, _)
        ):
            // Popover and preview selection are presentation state owned by
            // SessionIndexTableController. They must not replace this row's
            // NSHostingView root while AppKit is applying or laying out rows.
            return lhsSection == rhsSection
                && lhsLimit == rhsLimit
                && lhsDragged == rhsDragged
                && lhsCollapsed == rhsCollapsed
        case let (.gap(lhsKey, lhsValid, _), .gap(rhsKey, rhsValid, _)):
            return lhsKey == rhsKey && lhsValid == rhsValid
        default:
            return false
        }
    }
}
