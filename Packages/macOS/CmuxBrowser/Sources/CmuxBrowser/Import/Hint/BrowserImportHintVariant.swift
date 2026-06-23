/// The blank-tab import-hint presentation style the browser shows to nudge
/// users toward importing their existing browser data.
///
/// The raw values are the persisted `UserDefaults` representation, so the cases
/// and their `rawValue`s are wire/Defaults-stable and must not be renamed.
public enum BrowserImportHintVariant: String, CaseIterable, Identifiable, Sendable {
    case inlineStrip
    case floatingCard
    case toolbarChip
    case settingsOnly

    public var id: String { rawValue }
}
