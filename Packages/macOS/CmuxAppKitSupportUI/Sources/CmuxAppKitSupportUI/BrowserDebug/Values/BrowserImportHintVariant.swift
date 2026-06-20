#if canImport(AppKit)

public import Foundation

/// The blank-tab import-hint presentation style the import-hint debug panel
/// previews.
///
/// The raw values and `UserDefaults` key are byte-identical to the app target's
/// live import-hint settings, so toggling the debug panel drives the same stored
/// state the running browser reads. The `static` members here are constants and a
/// resolution factory on the value type they produce, not a stateless namespace.
public enum BrowserImportHintVariant: String, CaseIterable, Identifiable, Sendable {
    case inlineStrip
    case floatingCard
    case toolbarChip
    case settingsOnly

    public var id: String { rawValue }

    /// The `UserDefaults` key backing the selected variant.
    public static let storageKey = "browserImportHintVariant"

    /// The shipped default variant when no value is stored.
    public static let defaultVariant: BrowserImportHintVariant = .toolbarChip

    /// Resolves a stored raw value into a variant, falling back to
    /// ``defaultVariant`` when the value is missing or unrecognized.
    public static func resolved(from rawValue: String?) -> BrowserImportHintVariant {
        guard let rawValue, let variant = BrowserImportHintVariant(rawValue: rawValue) else {
            return defaultVariant
        }
        return variant
    }

    /// The human-readable title shown in the debug panel's variant picker.
    public var title: String {
        switch self {
        case .inlineStrip:
            return "Inline Strip"
        case .floatingCard:
            return "Floating Card"
        case .toolbarChip:
            return "Toolbar Chip"
        case .settingsOnly:
            return "Settings Only"
        }
    }

    /// The longer description shown beneath the variant picker.
    public var detail: String {
        switch self {
        case .inlineStrip:
            return "Shows a thin hint bar at the top of blank browser tabs."
        case .floatingCard:
            return "Shows the fuller callout card inside blank browser tabs."
        case .toolbarChip:
            return "Moves the hint into a small toolbar chip beside the browser controls."
        case .settingsOnly:
            return "Hides the blank-tab hint and leaves Browser settings as the only home."
        }
    }
}

#endif
