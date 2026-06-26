/// The resolved placement of the import hint, computed from the configured
/// variant and the user's blank-tab and dismissal preferences.
///
/// The initializer encodes the precedence rules: the ``BrowserImportHintVariant/settingsOnly``
/// variant keeps the hint in Settings only; otherwise a hidden/dismissed hint is
/// suppressed everywhere; otherwise the variant maps directly to a blank-tab
/// placement with a visible Settings entry.
public struct BrowserImportHintPresentation: Equatable, Sendable {
    /// Where the hint is placed on a blank tab.
    public let blankTabPlacement: BrowserImportHintBlankTabPlacement
    /// Whether and how the hint is represented in Settings.
    public let settingsStatus: BrowserImportHintSettingsStatus

    /// Resolves the hint placement from the configured variant and preferences.
    ///
    /// - Parameters:
    ///   - variant: The configured hint presentation style.
    ///   - showOnBlankTabs: Whether the user allows the hint on blank tabs.
    ///   - isDismissed: Whether the user has dismissed the hint.
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
