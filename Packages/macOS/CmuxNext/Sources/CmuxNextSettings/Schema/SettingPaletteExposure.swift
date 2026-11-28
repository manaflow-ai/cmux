/// Whether a setting has a palette row (`SettingsPaletteSource`).
public nonisolated enum SettingPaletteExposure: Sendable, Hashable {
    case exposed
    /// Kept out of the palette, with the reason.
    case hidden(String)
}

/// Whether the Settings page shows a setting's row. A hidden key is still in
/// the export, write validation, `settings.set` and the agent policy; another
/// surface edits it (the sidebar row menu mutes a workspace).
public nonisolated enum SettingPageExposure: Sendable, Hashable {
    case shown
    /// Kept off the Settings page, with the reason.
    case hidden(String)
}
