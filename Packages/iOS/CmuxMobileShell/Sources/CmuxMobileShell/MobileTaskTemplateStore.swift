public import CMUXMobileCore
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
    private let diagnosticLog: DiagnosticLog?

    // v4 resets the unshipped seeds onto the environment-only prompt contract.
    private static let templatesKey = "cmux.mobile.taskTemplates.v4"
    private static let seededKey = "cmux.mobile.taskTemplates.seeded.v4"
    private static let builtInProtectionMigrationKey =
        "cmux.mobile.taskTemplates.builtInProtectionMigrated.v1"
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
    private static let legacyComposerDraftKey = "cmux.mobile.taskComposer.draft.v1"
    private static let composerDraftsKey = "cmux.mobile.taskComposer.drafts.v1"
    private static let recentDirectoryLimit = 20
    private static let composerDraftLimit = 20

    /// Draft-owned attachment bytes live under this directory, one
    /// subdirectory per draft id, so deleting a draft is one folder removal.
    private let attachmentFilesRootDirectory: URL

    /// Creates a task template store backed by `defaults`.
    /// - Parameters:
    ///   - defaults: The `UserDefaults` instance to persist into.
    ///   - attachmentFilesRootDirectory: Root for preserved draft attachment
    ///     files; defaults to Application Support.
    public init(
        defaults: UserDefaults,
        diagnosticLog: DiagnosticLog? = nil,
        attachmentFilesRootDirectory: URL =
            UserDefaultsMobileTaskTemplateStore.defaultComposerAttachmentsRootDirectory()
    ) {
        self.defaults = defaults
        self.diagnosticLog = diagnosticLog
        self.attachmentFilesRootDirectory = attachmentFilesRootDirectory
    }

    /// The production location for preserved draft attachment files.
    public static func defaultComposerAttachmentsRootDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("composer-draft-attachments", isDirectory: true)
    }

    /// Returns all stored templates, seeding defaults on the first read.
    public func listTemplates() -> [MobileTaskTemplate] {
        seedIfNeeded()
        let migrated = migrateBuiltInProtectionIfNeeded(loadTemplates())
        return reconcileBuiltInTemplates(migrated)
    }

    /// Appends a template and persists the full list.
    public func addTemplate(_ template: MobileTaskTemplate) {
        var templates = listTemplates()
        var customTemplate = template
        customTemplate.isBuiltIn = false
        customTemplate.builtInKind = nil
        templates.append(customTemplate)
        saveTemplates(templates)
    }

    /// Replaces an existing template with the same id.
    public func updateTemplate(_ template: MobileTaskTemplate) {
        var templates = listTemplates()
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        var updatedTemplate = template
        updatedTemplate.isBuiltIn = templates[index].isBuiltIn
        updatedTemplate.builtInKind = templates[index].builtInKind
        templates[index] = updatedTemplate
        saveTemplates(templates)
    }

    /// Deletes templates in one load, scan, and persistence update.
    public func deleteTemplates(ids: Set<MobileTaskTemplate.ID>) {
        guard !ids.isEmpty else { return }
        var templates = listTemplates()
        let deletedIDs = Set(templates.lazy.compactMap { template in
            ids.contains(template.id) && !template.isBuiltIn ? template.id : nil
        })
        guard !deletedIDs.isEmpty else { return }
        templates.removeAll { deletedIDs.contains($0.id) }
        saveTemplates(templates)
        if let lastTemplateID = lastTemplateID(), deletedIDs.contains(lastTemplateID) {
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

    /// Returns every unsent task-composer draft, newest first, adopting a
    /// legacy single-slot draft into the collection on first read.
    public func composerDrafts() -> [MobileTaskComposerSavedDraft] {
        migrateLegacyComposerDraftIfNeeded()
        guard let data = defaults.data(forKey: Self.composerDraftsKey) else { return [] }
        do {
            return try decoder.decode([MobileTaskComposerSavedDraft].self, from: data)
        } catch {
            diagnosticLog?.recordAppEvent(
                .draftPersistenceFailed,
                failure: .protocolViolation
            )
            return []
        }
    }

    /// Inserts or replaces one draft by id at the front of the collection,
    /// dropping the oldest entries (and their attachment files) beyond the
    /// bounded storage limit. Files owned by attachments the replacement no
    /// longer references are deleted so removed attachments leave no bytes.
    public func saveComposerDraft(_ draft: MobileTaskComposerSavedDraft) {
        var drafts = composerDrafts()
        if let previous = drafts.first(where: { $0.id == draft.id }) {
            let keptPaths = Set(draft.content.attachments.map(\.relativePath))
            for dropped in previous.content.attachments
            where !keptPaths.contains(dropped.relativePath) {
                guard let url = composerAttachmentFileURL(
                    relativePath: dropped.relativePath
                ) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
        drafts.removeAll { $0.id == draft.id }
        drafts.insert(draft, at: 0)
        if drafts.count > Self.composerDraftLimit {
            let evicted = drafts.suffix(from: Self.composerDraftLimit)
            drafts.removeLast(drafts.count - Self.composerDraftLimit)
            removeAttachmentDirectories(draftIDs: Set(evicted.map(\.id)))
        }
        saveComposerDrafts(drafts)
    }

    /// Deletes the drafts with the provided ids in one persistence update,
    /// including any preserved attachment files they own.
    public func deleteComposerDrafts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        removeAttachmentDirectories(draftIDs: ids)
        var drafts = composerDrafts()
        let countBefore = drafts.count
        drafts.removeAll { ids.contains($0.id) }
        guard drafts.count != countBefore else { return }
        saveComposerDrafts(drafts)
    }

    /// Copies staged attachment bytes into draft-owned storage. An existing
    /// copy of the same attachment is reused so per-leave persists stay cheap.
    public func persistComposerAttachmentFile(
        draftID: UUID,
        attachmentID: UUID,
        preferredExtension: String,
        from sourceURL: URL
    ) throws -> String {
        let sanitizedExtension = preferredExtension
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
        let fileName = attachmentID.uuidString
            + "." + (sanitizedExtension.isEmpty ? "bin" : sanitizedExtension)
        let relativePath = draftID.uuidString + "/" + fileName
        let draftDirectory = attachmentFilesRootDirectory
            .appendingPathComponent(draftID.uuidString, isDirectory: true)
        let destination = draftDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            return relativePath
        }
        try FileManager.default.createDirectory(
            at: draftDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return relativePath
    }

    /// Returns the location of preserved attachment bytes, or `nil` when the
    /// path is invalid or the file no longer exists.
    public func composerAttachmentFileURL(relativePath: String) -> URL? {
        let components = relativePath.split(separator: "/")
        guard components.count == 2,
              !relativePath.contains(".."),
              !relativePath.hasPrefix("/") else {
            return nil
        }
        let url = attachmentFilesRootDirectory
            .appendingPathComponent(String(components[0]), isDirectory: true)
            .appendingPathComponent(String(components[1]))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func removeAttachmentDirectories(draftIDs: Set<UUID>) {
        for draftID in draftIDs {
            let directory = attachmentFilesRootDirectory
                .appendingPathComponent(draftID.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Adopts the pre-collection single draft as the newest saved draft so an
    /// update never discards what the user prepared on an older build.
    private func migrateLegacyComposerDraftIfNeeded() {
        guard let data = defaults.data(forKey: Self.legacyComposerDraftKey) else { return }
        defaults.removeObject(forKey: Self.legacyComposerDraftKey)
        guard let legacy = try? decoder.decode(MobileTaskComposerDraft.self, from: data),
              !legacy.isEffectivelyEmpty else { return }
        var drafts: [MobileTaskComposerSavedDraft] = []
        if let existing = defaults.data(forKey: Self.composerDraftsKey),
           let decoded = try? decoder.decode([MobileTaskComposerSavedDraft].self, from: existing) {
            drafts = decoded
        }
        drafts.insert(
            MobileTaskComposerSavedDraft(updatedAt: Date(), content: legacy),
            at: 0
        )
        saveComposerDrafts(drafts)
    }

    private func saveComposerDrafts(_ drafts: [MobileTaskComposerSavedDraft]) {
        guard !drafts.isEmpty else {
            defaults.removeObject(forKey: Self.composerDraftsKey)
            return
        }
        guard let data = try? encoder.encode(drafts) else {
            diagnosticLog?.recordAppEvent(
                .draftPersistenceFailed,
                failure: .protocolViolation
            )
            return
        }
        defaults.set(data, forKey: Self.composerDraftsKey)
    }

    /// Removes every account-derived template, selection, directory, and draft.
    public func clearAllUserData() {
        let keys = [
            Self.templatesKey,
            Self.seededKey,
            Self.builtInProtectionMigrationKey,
            Self.lastTemplateIDKey,
            Self.lastMacDeviceIDKey,
            Self.legacyComposerDraftKey,
            Self.composerDraftsKey,
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
        try? FileManager.default.removeItem(at: attachmentFilesRootDirectory)
    }

    private func seedIfNeeded() {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        for key in Self.legacyKeys {
            defaults.removeObject(forKey: key)
        }
        saveTemplates(defaultTemplates())
        defaults.set(true, forKey: Self.seededKey)
    }

    private func defaultTemplates() -> [MobileTaskTemplate] {
        MobileTaskTemplate.seedDefaults(
            claudeName: L10n.string("mobile.taskComposer.template.seed.claude", defaultValue: "Claude"),
            codexName: L10n.string("mobile.taskComposer.template.seed.codex", defaultValue: "Codex"),
            openCodeName: L10n.string("mobile.taskComposer.template.seed.opencode", defaultValue: "OpenCode"),
            shellName: L10n.string("mobile.taskComposer.template.seed.shell", defaultValue: "Shell")
        )
    }

    private func loadTemplates() -> [MobileTaskTemplate] {
        guard let data = defaults.data(forKey: Self.templatesKey) else {
            return []
        }
        do {
            return try decoder.decode([MobileTaskTemplate].self, from: data)
        } catch {
            diagnosticLog?.recordAppEvent(
                .templatePersistenceFailed,
                failure: .protocolViolation
            )
            return []
        }
    }

    private func migrateBuiltInProtectionIfNeeded(
        _ templates: [MobileTaskTemplate]
    ) -> [MobileTaskTemplate] {
        guard !defaults.bool(forKey: Self.builtInProtectionMigrationKey) else {
            return templates
        }

        var migratedTemplates = templates
        var didChange = false
        for index in migratedTemplates.indices
        where !migratedTemplates[index].isBuiltIn
            && Self.legacyBuiltInKind(for: migratedTemplates[index]) != nil {
            migratedTemplates[index].isBuiltIn = true
            didChange = true
        }
        if didChange {
            saveTemplates(migratedTemplates)
        }
        defaults.set(true, forKey: Self.builtInProtectionMigrationKey)
        return migratedTemplates
    }

    /// Repairs the shipped/custom ownership boundary on every read. The
    /// reconciliation is intentionally idempotent so a seed removed by an
    /// older build is restored, while editable built-in rows retain their
    /// stable identity and custom rows remain deletable.
    private func reconcileBuiltInTemplates(
        _ templates: [MobileTaskTemplate]
    ) -> [MobileTaskTemplate] {
        let defaultsByKind = Dictionary(
            uniqueKeysWithValues: defaultTemplates().compactMap { template in
                template.builtInKind.map { ($0, template) }
            }
        )
        var working = templates
        var claimedIndices = Set<Int>()
        var resolved: [MobileTaskBuiltInTemplateKind: MobileTaskTemplate] = [:]

        func claim(_ index: Int, as kind: MobileTaskBuiltInTemplateKind) {
            var template = working[index]
            template.isBuiltIn = true
            template.builtInKind = kind
            working[index] = template
            claimedIndices.insert(index)
            resolved[kind] = template
        }

        // New data carries an explicit identity, so edits to name, icon, or
        // command cannot turn a shipped row into a deletable custom row.
        for kind in MobileTaskBuiltInTemplateKind.allCases {
            if let index = working.indices.first(where: {
                !claimedIndices.contains($0) && working[$0].builtInKind == kind
            }) {
                claim(index, as: kind)
            }
        }

        // Legacy v4 data has no identity. Claim the first canonical signature
        // for each missing kind, which matches the original seed-before-custom
        // ordering and leaves later matching rows custom.
        for kind in MobileTaskBuiltInTemplateKind.allCases where resolved[kind] == nil {
            if let index = working.indices.first(where: {
                !claimedIndices.contains($0)
                    && Self.legacyBuiltInKind(for: working[$0]) == kind
            }) {
                claim(index, as: kind)
            }
        }

        // A legacy built-in may have been edited before this migration. It is
        // still protected, so assign remaining shipped slots by their original
        // relative order before creating any missing seed rows.
        let unknownProtectedIndices = working.indices.filter {
            !claimedIndices.contains($0)
                && working[$0].isBuiltIn
                && working[$0].builtInKind == nil
                && Self.legacyBuiltInKind(for: working[$0]) == nil
        }
        for kind in MobileTaskBuiltInTemplateKind.allCases where resolved[kind] == nil {
            guard let index = unknownProtectedIndices.first(where: { !claimedIndices.contains($0) }) else {
                break
            }
            claim(index, as: kind)
        }

        // Re-create any shipped row that was actually removed by an older
        // build. New rows receive a fresh id, while the custom list is kept.
        for kind in MobileTaskBuiltInTemplateKind.allCases where resolved[kind] == nil {
            guard let template = defaultsByKind[kind] else { continue }
            resolved[kind] = template
        }

        var reconciled = MobileTaskBuiltInTemplateKind.allCases.compactMap { resolved[$0] }
        for index in working.indices where !claimedIndices.contains(index) {
            var template = working[index]
            // A duplicate legacy signature or an old provenance bit without a
            // corresponding shipped slot is custom data, and must stay deletable.
            template.isBuiltIn = false
            template.builtInKind = nil
            reconciled.append(template)
        }

        if reconciled != templates {
            saveTemplates(reconciled)
        }
        return reconciled
    }

    private static func legacyBuiltInKind(
        for template: MobileTaskTemplate
    ) -> MobileTaskBuiltInTemplateKind? {
        guard template.defaultDirectory == nil else { return nil }
        switch (template.icon, template.command) {
        case ("agent:claude", "claude -- \"$CMUX_TASK_PROMPT\""):
            return .claude
        case ("agent:codex", "codex -- \"$CMUX_TASK_PROMPT\""):
            return .codex
        case ("agent:opencode", "opencode --prompt \"$CMUX_TASK_PROMPT\""):
            return .openCode
        case ("terminal", ""):
            return .shell
        default:
            return nil
        }
    }

    private func saveTemplates(_ templates: [MobileTaskTemplate]) {
        guard let data = try? encoder.encode(templates) else {
            diagnosticLog?.recordAppEvent(
                .templatePersistenceFailed,
                failure: .protocolViolation
            )
            return
        }
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
