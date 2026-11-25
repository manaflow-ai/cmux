import os

extension BrowserOmnibarSetting {
    /// Import from Browser's Search Engines: the other browser's default
    /// engine becomes `browser.searchEngine` (a built-in id, or `custom` with
    /// its addresses; `import.search_engine` lists the writes in order). The
    /// person checked the kind and ran the import, so it is their write; a
    /// managed key stays as policy set it.
    @MainActor public static func applyImported(_ choice: (engine: String, search: String?, suggest: String?), in settings: SettingsController) async {
        let (engine, search, suggest) = choice
        let request: JSONValue = ["engine": .string(engine), "search": search.map(JSONValue.string) ?? .null,
                                  "suggest": suggest.map(JSONValue.string) ?? .null]
        do {
            for write in try SettingsRust.call("import.search_engine", request)["writes"]?.arrayValue ?? [] {
                guard let path = write["path"]?.arrayValue?.compactMap(\.stringValue) else { continue }
                let value = write["value"]
                try await settings.setSetting(at: path, to: value?.isNull == true ? nil : value, by: .user)
            }
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "omnibar")
                .error("imported search engine not applied: \(String(describing: error), privacy: .public)")
        }
    }
}
