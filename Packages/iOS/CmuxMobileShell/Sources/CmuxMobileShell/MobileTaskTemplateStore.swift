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

    // v4 resets the unshipped seeds onto the environment-only prompt contract.
    private static let templatesKey = "cmux.mobile.taskTemplates.v4"
    private static let seededKey = "cmux.mobile.taskTemplates.seeded.v4"
    private static let legacyKeys = [
        "cmux.mobile.taskTemplates.v1",
        "cmux.mobile.taskTemplates.seeded.v1",
        "cmux.mobile.taskTemplates.v2",
        "cmux.mobile.taskTemplates.seeded.v2",
        "cmux.mobile.taskTemplates.v3",
        "cmux.mobile.taskTemplates.seeded.v3",
    ]
    private static let lastTemplateIDKey = "cmux.mobile.taskComposer.lastTemplateID"
    private static let lastMacDeviceIDKey = "cmux.mobile.taskComposer.lastMacDeviceID"
    private static let lastDirectoryPrefix = "cmux.mobile.taskComposer.lastDirectory."
    private static let recentDirectoriesPrefix = "cmux.mobile.taskComposer.recentDirectories.v1."
    private static let composerDraftKey = "cmux.mobile.taskComposer.draft.v1"
    private static let recentDirectoryLimit = 20

    /// Creates a task template store backed by `defaults`.
    /// - Parameter defaults: The `UserDefaults` instance to persist into.
    public init(defaults: UserDefaults) {
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

    /// Deletes templates in one load, scan, and persistence update.
    public func deleteTemplates(ids: Set<MobileTaskTemplate.ID>) {
        guard !ids.isEmpty else { return }
        var templates = listTemplates()
        templates.removeAll { ids.contains($0.id) }
        saveTemplates(templates)
        if let lastTemplateID = lastTemplateID(), ids.contains(lastTemplateID) {
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

    /// Returns successful directories for one Mac, newest first.
    public func recentDirectories(macDeviceID: String) -> [MobileTaskRecentDirectory] {
        guard let data = defaults.data(forKey: Self.recentDirectoriesPrefix + macDeviceID),
              let directories = try? decoder.decode([MobileTaskRecentDirectory].self, from: data) else {
            return []
        }
        return directories
    }

    /// Records one successful directory with exact UTF-8 identity and bounded storage.
    public func recordRecentDirectory(_ directory: String, macDeviceID: String, at date: Date) {
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let identity = MobileTaskDirectoryPathID(path: directory)
        var directories = recentDirectories(macDeviceID: macDeviceID)
        let previousUseCount = directories.first { MobileTaskDirectoryPathID(path: $0.path) == identity }?.useCount ?? 0
        let nextUseCount = previousUseCount == Int.max ? Int.max : previousUseCount + 1
        directories.removeAll { MobileTaskDirectoryPathID(path: $0.path) == identity }
        directories.insert(
            MobileTaskRecentDirectory(
                path: directory,
                lastUsedAt: date,
                useCount: nextUseCount
            ),
            at: 0
        )
        if directories.count > Self.recentDirectoryLimit {
            directories.removeLast(directories.count - Self.recentDirectoryLimit)
        }
        guard let data = try? encoder.encode(directories) else { return }
        defaults.set(data, forKey: Self.recentDirectoriesPrefix + macDeviceID)
    }

    /// Returns the unsent task-composer draft, if one was saved.
    public func composerDraft() -> MobileTaskComposerDraft? {
        guard let data = defaults.data(forKey: Self.composerDraftKey) else { return nil }
        return try? decoder.decode(MobileTaskComposerDraft.self, from: data)
    }

    /// Stores or clears the unsent task-composer draft.
    public func setComposerDraft(_ draft: MobileTaskComposerDraft?) {
        guard let draft else {
            defaults.removeObject(forKey: Self.composerDraftKey)
            return
        }
        guard let data = try? encoder.encode(draft) else { return }
        defaults.set(data, forKey: Self.composerDraftKey)
    }

    /// Removes every account-derived template, selection, directory, and draft.
    public func clearAllUserData() {
        let keys = [
            Self.templatesKey,
            Self.seededKey,
            Self.lastTemplateIDKey,
            Self.lastMacDeviceIDKey,
            Self.composerDraftKey,
        ] + Self.legacyKeys
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.lastDirectoryPrefix) {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.recentDirectoriesPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func seedIfNeeded() {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        for key in Self.legacyKeys {
            defaults.removeObject(forKey: key)
        }
        saveTemplates(MobileTaskTemplate.seedDefaults(
            claudeName: L10n.string("mobile.taskComposer.template.seed.claude", defaultValue: "Claude"),
            codexName: L10n.string("mobile.taskComposer.template.seed.codex", defaultValue: "Codex"),
            openCodeName: L10n.string("mobile.taskComposer.template.seed.opencode", defaultValue: "OpenCode"),
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
