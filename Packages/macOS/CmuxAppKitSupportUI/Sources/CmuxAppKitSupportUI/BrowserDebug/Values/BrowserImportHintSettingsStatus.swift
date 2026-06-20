#if canImport(AppKit)

/// Whether the import hint is surfaced in Browser settings for a given variant
/// and dismissal state.
///
/// Derived by ``BrowserImportHintPresentation``; surfaced read-only in the
/// import-hint debug panel.
public enum BrowserImportHintSettingsStatus: Equatable, Sendable {
    case visible
    case hidden
    case settingsOnly

    /// The human-readable label shown in the debug panel.
    public var title: String {
        switch self {
        case .visible:
            return "Visible"
        case .hidden:
            return "Hidden"
        case .settingsOnly:
            return "Settings Only"
        }
    }
}

#endif
