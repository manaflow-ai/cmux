/// The visual treatment used to surface the "import your data from another
/// browser" hint.
///
/// Persisted by raw value under
/// ``BrowserImportHintSettings/variantKey``; ``settingsOnly`` keeps the hint out
/// of blank tabs entirely, leaving it reachable only from Settings.
public enum BrowserImportHintVariant: String, CaseIterable, Identifiable, Sendable {
    /// An inline strip rendered within the blank-tab content.
    case inlineStrip
    /// A floating card overlaid on the blank tab.
    case floatingCard
    /// A compact chip anchored in the toolbar.
    case toolbarChip
    /// No blank-tab presentation; the hint lives only in Settings.
    case settingsOnly

    /// The stable identity used for `Identifiable`, equal to the raw value.
    public var id: String { rawValue }
}
