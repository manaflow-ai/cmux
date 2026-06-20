#if canImport(AppKit)

public import Foundation

/// The derived blank-tab placement and settings status for a given import-hint
/// configuration.
///
/// The derivation mirrors the app target's live import-hint logic exactly so the
/// debug panel's read-out matches what the running browser would show. The
/// `showOnBlankTabs`/`dismissed` `UserDefaults` keys are byte-identical to the app
/// target's, so the debug panel drives the same stored state.
public struct BrowserImportHintPresentation: Equatable, Sendable {
    /// The `UserDefaults` key for the "show on blank tabs" flag.
    public static let showOnBlankTabsKey = "browserImportHintShowOnBlankTabs"

    /// The `UserDefaults` key for the "dismissed" flag.
    public static let dismissedKey = "browserImportHintDismissed"

    /// The shipped default for the "show on blank tabs" flag.
    public static let defaultShowOnBlankTabs = true

    /// The shipped default for the "dismissed" flag.
    public static let defaultDismissed = false

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

#endif
