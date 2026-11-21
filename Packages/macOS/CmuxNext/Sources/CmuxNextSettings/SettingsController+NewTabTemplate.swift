import os

extension SettingsController {
    /// The New Tab page's style switch, saved as `tabs.newTabTemplate` through the schema as the
    /// Settings window writes it. Terminal and unknown values are ignored: `terminal` is a person's
    /// terminal-first choice (Make cmux Yours or Settings, cmux#48416), never a pick on the page itself.
    public func saveNewTabTemplate(_ value: String) async {
        guard let template = NewTabTemplate(rawValue: value), template != .terminal,
              let descriptor = SettingsSchema.descriptor(for: NewTabTemplate.configPath) else { return }
        // Retired pages (Composer, Cards, Default, Threads, Console) are no longer selectable.
        // Normalize page writes too, so a stale caller cannot put a retired value back into cmux.json.
        let savedTemplate = template.shipped
        do { try await setSetting(descriptor, to: .string(savedTemplate.rawValue), by: .caller("page")) } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "newtab")
                .error("new tab template write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
