extension SettingsController {
    /// Rewrites the settings whose old values still read, once at launch, so Settings and the palette
    /// show them: `app.quitBehavior: "end"` (`migrateLegacyQuitBehavior`) and the first
    /// `sidebar.textSize` values (`migrateLegacySidebarTextSize`). Returns whether any wrote.
    @discardableResult
    public func migrateLegacySettingValues() async throws -> Bool {
        let quit = try await migrateLegacyQuitBehavior()
        let textSize = try await migrateLegacySidebarTextSize()
        return quit || textSize
    }
}
