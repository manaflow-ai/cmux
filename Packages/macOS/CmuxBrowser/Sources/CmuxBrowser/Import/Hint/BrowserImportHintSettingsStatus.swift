/// Whether and how the import-data hint surfaces in Browser settings.
public enum BrowserImportHintSettingsStatus: Equatable, Sendable {
    case visible
    case hidden
    case settingsOnly
}
