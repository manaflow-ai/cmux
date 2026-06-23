/// The derived blank-tab placement and settings status for a given import-hint
/// configuration.
///
/// The initializer derives both fields from the selected ``BrowserImportHintVariant``
/// and the blank-tab/dismissed flags, so it is the single source of truth for how
/// the import-data hint presents. The derivation is byte-faithful to the app
/// target's original logic.
public struct BrowserImportHintPresentation: Equatable, Sendable {
    /// Where the hint appears on a blank tab.
    public let blankTabPlacement: BrowserImportHintBlankTabPlacement

    /// Whether the hint is surfaced in Browser settings.
    public let settingsStatus: BrowserImportHintSettingsStatus

    /// Derives the presentation from a variant and the blank-tab/dismissed flags.
    public init(
        variant: BrowserImportHintVariant,
        showOnBlankTabs: Bool,
        isDismissed: Bool
    ) {
        if variant == .settingsOnly {
            blankTabPlacement = .hidden
            settingsStatus = .settingsOnly
            return
        }

        if !showOnBlankTabs || isDismissed {
            blankTabPlacement = .hidden
            settingsStatus = .hidden
            return
        }

        switch variant {
        case .inlineStrip:
            blankTabPlacement = .inlineStrip
        case .floatingCard:
            blankTabPlacement = .floatingCard
        case .toolbarChip:
            blankTabPlacement = .toolbarChip
        case .settingsOnly:
            blankTabPlacement = .hidden
        }
        settingsStatus = .visible
    }
}
