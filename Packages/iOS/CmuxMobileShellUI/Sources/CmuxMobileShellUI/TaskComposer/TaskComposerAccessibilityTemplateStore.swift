#if os(iOS) && DEBUG
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

@MainActor
final class TaskComposerAccessibilityTemplateStore: MobileTaskTemplateStoring {
    private var templates = MobileTaskTemplate.seedDefaults(
        claudeName: L10n.string("mobile.taskComposer.template.seed.claude", defaultValue: "Claude"),
        codexName: L10n.string("mobile.taskComposer.template.seed.codex", defaultValue: "Codex"),
        openCodeName: L10n.string("mobile.taskComposer.template.seed.opencode", defaultValue: "OpenCode"),
        shellName: L10n.string("mobile.taskComposer.template.seed.shell", defaultValue: "Shell")
    )
    private var selectedTemplateID: MobileTaskTemplate.ID?
    private var selectedMacDeviceID: String?
    private var directoriesByMacDeviceID: [String: String] = [:]
    private var recentsByMacDeviceID: [String: [MobileTaskRecentDirectory]] = [:]
    private var drafts: [MobileTaskComposerSavedDraft] = []

    func listTemplates() -> [MobileTaskTemplate] {
        templates
    }

    func addTemplate(_ template: MobileTaskTemplate) {
        var customTemplate = template
        customTemplate.isBuiltIn = false
        customTemplate.builtInKind = nil
        templates.append(customTemplate)
    }

    func updateTemplate(_ template: MobileTaskTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        var updatedTemplate = template
        updatedTemplate.isBuiltIn = templates[index].isBuiltIn
        updatedTemplate.builtInKind = templates[index].builtInKind
        templates[index] = updatedTemplate
    }

    func deleteTemplates(ids: Set<MobileTaskTemplate.ID>) {
        let deletedIDs = Set(templates.lazy.compactMap { template in
            ids.contains(template.id) && !template.isBuiltIn ? template.id : nil
        })
        templates.removeAll { deletedIDs.contains($0.id) }
        if let selectedID = selectedTemplateID, deletedIDs.contains(selectedID) {
            selectedTemplateID = nil
        }
    }

    func lastTemplateID() -> MobileTaskTemplate.ID? {
        selectedTemplateID
    }

    func setLastTemplateID(_ id: MobileTaskTemplate.ID?) {
        selectedTemplateID = id
    }

    func lastMacDeviceID() -> String? {
        selectedMacDeviceID
    }

    func setLastMacDeviceID(_ id: String?) {
        selectedMacDeviceID = id
    }

    func lastDirectory(macDeviceID: String) -> String? {
        directoriesByMacDeviceID[macDeviceID]
    }

    func setLastDirectory(_ directory: String?, macDeviceID: String) {
        directoriesByMacDeviceID[macDeviceID] = directory
    }

    func recentDirectories(macDeviceID: String) -> [MobileTaskRecentDirectory] {
        recentsByMacDeviceID[macDeviceID] ?? []
    }

    func recordRecentDirectory(_ directory: String, macDeviceID: String, at date: Date) {
        var recents = recentDirectories(macDeviceID: macDeviceID)
        let id = MobileTaskDirectoryPathID(path: directory)
        let count = recents.first { MobileTaskDirectoryPathID(path: $0.path) == id }?.useCount ?? 0
        recents.removeAll { MobileTaskDirectoryPathID(path: $0.path) == id }
        let nextCount = count == Int.max ? Int.max : count + 1
        recents.insert(.init(path: directory, lastUsedAt: date, useCount: nextCount), at: 0)
        recentsByMacDeviceID[macDeviceID] = Array(recents.prefix(20))
    }

    func composerDrafts() -> [MobileTaskComposerSavedDraft] {
        drafts
    }

    func saveComposerDraft(_ draft: MobileTaskComposerSavedDraft) {
        drafts.removeAll { $0.id == draft.id }
        drafts.insert(draft, at: 0)
    }

    func deleteComposerDrafts(ids: Set<UUID>) {
        drafts.removeAll { ids.contains($0.id) }
        for id in ids {
            try? FileManager.default.removeItem(at: attachmentDirectory(draftID: id))
        }
    }

    func persistComposerAttachmentFile(
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
        let directory = attachmentDirectory(draftID: draftID)
        let destination = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
        return draftID.uuidString + "/" + fileName
    }

    func composerAttachmentFileURL(relativePath: String) -> URL? {
        let url = attachmentsRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var attachmentsRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-accessibility-draft-attachments", isDirectory: true)
    }

    private func attachmentDirectory(draftID: UUID) -> URL {
        attachmentsRoot.appendingPathComponent(draftID.uuidString, isDirectory: true)
    }

    func clearAllUserData() {
        templates.removeAll()
        selectedTemplateID = nil
        selectedMacDeviceID = nil
        directoriesByMacDeviceID.removeAll()
        recentsByMacDeviceID.removeAll()
        drafts.removeAll()
        try? FileManager.default.removeItem(at: attachmentsRoot)
    }
}
#endif
