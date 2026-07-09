/// Whether and how the import hint is represented in Settings.
///
/// Derived by ``BrowserImportHintPresentation`` alongside
/// ``BrowserImportHintBlankTabPlacement``.
public enum BrowserImportHintSettingsStatus: Equatable, Sendable {
    /// The hint's Settings entry is shown and active.
    case visible
    /// The hint is hidden everywhere, including Settings.
    case hidden
    /// The hint is reachable only from Settings, not from blank tabs.
    case settingsOnly
}
