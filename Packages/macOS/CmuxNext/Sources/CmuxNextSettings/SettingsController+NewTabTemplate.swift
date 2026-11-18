import os

extension SettingsController {
    /// The New Tab page's style switch, saved as `tabs.newTabTemplate` through the schema as the
    /// Settings window writes it. Terminal and unknown values are ignored: New Tab never opens a
    /// terminal by itself.
    public func saveNewTabTemplate(_ value: String) async {
        // A retired template (NewTabTemplate.retired) is saved as Minimal, so a stale caller cannot
        // put one back into cmux.json.
        guard let template = NewTabTemplate.reading(value), template != .terminal,
              let descriptor = SettingsSchema.descriptor(for: NewTabTemplate.configPath) else { return }
        do { try await setSetting(descriptor, to: .string(template.rawValue), by: .caller("page")) } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "newtab")
                .error("new tab template write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
