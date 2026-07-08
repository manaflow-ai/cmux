public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import Foundation

/// `UserDefaults`-backed mobile task template store. Not `@Observable`: it has
/// no tracked stored state; views re-read via `listTemplates()` after mutations.
@MainActor
public final class UserDefaultsMobileTaskTemplateStore: MobileTaskTemplateStoring {
    // UserDefaults is Apple-documented thread-safe; this main-actor store reads
    // and writes synchronously through an injected defaults instance.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static let templatesKey = "cmux.mobile.taskTemplates.v1"
    private static let seededKey = "cmux.mobile.taskTemplates.seeded.v1"
    private static let lastTemplateIDKey = "cmux.mobile.taskComposer.lastTemplateID"
    private static let lastMacDeviceIDKey = "cmux.mobile.taskComposer.lastMacDeviceID"
    private static let lastDirectoryPrefix = "cmux.mobile.taskComposer.lastDirectory."

    /// Creates a task template store backed by `defaults`.
    /// - Parameter defaults: The `UserDefaults` instance to persist into.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns all stored templates, seeding defaults on the first read.
    public func listTemplates() -> [MobileTaskTemplate] {
        seedIfNeeded()
        return loadTemplates()
    }

    /// Appends a template and persists the full list.
    public func addTemplate(_ template: MobileTaskTemplate) {
        var templates = listTemplates()
        templates.append(template)
        saveTemplates(templates)
    }

    /// Replaces an existing template with the same id.
    public func updateTemplate(_ template: MobileTaskTemplate) {
        var templates = listTemplates()
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
        saveTemplates(templates)
    }

    /// Deletes the template with `id`.
    public func deleteTemplate(id: MobileTaskTemplate.ID) {
        var templates = listTemplates()
        templates.removeAll { $0.id == id }
        saveTemplates(templates)
        if lastTemplateID() == id {
            setLastTemplateID(nil)
        }
    }

    /// Returns the last selected template id, if any.
    public func lastTemplateID() -> MobileTaskTemplate.ID? {
        guard let raw = defaults.string(forKey: Self.lastTemplateIDKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// Stores the last selected template id.
    public func setLastTemplateID(_ id: MobileTaskTemplate.ID?) {
        setOptional(id?.uuidString, forKey: Self.lastTemplateIDKey)
    }

    /// Returns the last selected Mac device id, if any.
    public func lastMacDeviceID() -> String? {
        defaults.string(forKey: Self.lastMacDeviceIDKey)
    }

    /// Stores the last selected Mac device id.
    public func setLastMacDeviceID(_ id: String?) {
        setOptional(id, forKey: Self.lastMacDeviceIDKey)
    }

    /// Returns the last successful directory for one Mac.
    public func lastDirectory(macDeviceID: String) -> String? {
        defaults.string(forKey: Self.lastDirectoryPrefix + macDeviceID)
    }

    /// Stores the last successful directory for one Mac.
    public func setLastDirectory(_ directory: String?, macDeviceID: String) {
        setOptional(directory, forKey: Self.lastDirectoryPrefix + macDeviceID)
    }

    private func seedIfNeeded() {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        saveTemplates(MobileTaskTemplate.seedDefaults(
            claudeName: L10n.string("mobile.taskComposer.template.seed.claude", defaultValue: "Claude"),
            codexName: L10n.string("mobile.taskComposer.template.seed.codex", defaultValue: "Codex"),
            shellName: L10n.string("mobile.taskComposer.template.seed.shell", defaultValue: "Shell")
        ))
        defaults.set(true, forKey: Self.seededKey)
    }

    private func loadTemplates() -> [MobileTaskTemplate] {
        guard let data = defaults.data(forKey: Self.templatesKey),
              let templates = try? decoder.decode([MobileTaskTemplate].self, from: data) else {
            return []
        }
        return templates
    }

    private func saveTemplates(_ templates: [MobileTaskTemplate]) {
        guard let data = try? encoder.encode(templates) else { return }
        defaults.set(data, forKey: Self.templatesKey)
    }

    private func setOptional(_ value: String?, forKey key: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
