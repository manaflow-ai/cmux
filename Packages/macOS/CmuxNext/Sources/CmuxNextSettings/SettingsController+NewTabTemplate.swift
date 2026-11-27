import os

extension SettingsController {
    /// The New Tab page's style switch, saved as `tabs.newTabTemplate` through the schema as the
    /// Settings window writes it. Terminal and unknown values are ignored: New Tab never opens a
    /// terminal by itself.
    public func saveNewTabTemplate(_ value: String) async {
        guard let template = NewTabTemplate(rawValue: value), template != .terminal,
              let descriptor = SettingsSchema.descriptor(for: NewTabTemplate.configPath) else { return }
        // The old Composer page is no longer selectable. Normalize page writes too, so a stale
        // caller cannot put the retired value back into cmux.json.
        let savedTemplate: NewTabTemplate = template == .composer ? .minimal : template
        do { try await setSetting(descriptor, to: .string(savedTemplate.rawValue), by: .caller("page")) } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "newtab")
                .error("new tab template write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
