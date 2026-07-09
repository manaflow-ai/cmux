#if canImport(AppKit)

/// Where the import hint appears on a blank browser tab for a given variant and
/// dismissal state.
///
/// Derived by ``BrowserImportHintPresentation`` from the selected variant and the
/// blank-tab/dismissed flags; surfaced read-only in the import-hint debug panel.
public enum BrowserImportHintBlankTabPlacement: Equatable, Sendable {
    case hidden
    case inlineStrip
    case floatingCard
    case toolbarChip

    /// The human-readable label shown in the debug panel.
    public var title: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .inlineStrip:
            return "Inline Strip"
        case .floatingCard:
            return "Floating Card"
        case .toolbarChip:
            return "Toolbar Chip"
        }
    }
}

#endif
