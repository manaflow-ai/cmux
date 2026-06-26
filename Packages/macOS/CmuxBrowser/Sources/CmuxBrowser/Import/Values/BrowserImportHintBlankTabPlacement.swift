/// Where, if anywhere, the import hint is placed on a blank tab.
///
/// Derived by ``BrowserImportHintPresentation`` from the configured
/// ``BrowserImportHintVariant`` and the user's blank-tab/dismissal preferences.
public enum BrowserImportHintBlankTabPlacement: Equatable, Sendable {
    /// The hint is not shown on blank tabs.
    case hidden
    /// The hint is shown as an inline strip within the blank-tab content.
    case inlineStrip
    /// The hint is shown as a floating card overlaid on the blank tab.
    case floatingCard
    /// The hint is shown as a compact chip anchored in the toolbar.
    case toolbarChip
}
