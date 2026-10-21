import os

extension BrowserOmnibarSetting {
    /// Import from Browser's Search Engines: the other browser's default
    /// engine becomes `browser.searchEngine` (a built-in id, or `custom` with
    /// its addresses). The person checked the kind and ran the import, so it
    /// is their write; a managed key stays as policy set it.
    @MainActor public static func applyImported(_ choice: (engine: String, search: String?, suggest: String?), in settings: SettingsController) async {
        let (engine, search, suggest) = choice
        do {
            if engine == "custom", let search {
                try await settings.setSetting(at: customSearchPath, to: .string(search), by: .user)
                try await settings.setSetting(at: customSuggestPath, to: suggest.map(JSONValue.string), by: .user)
            }
            try await settings.setSetting(at: searchEnginePath, to: .string(engine), by: .user)
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "omnibar")
                .error("imported search engine not applied: \(String(describing: error), privacy: .public)")
        }
    }
}
