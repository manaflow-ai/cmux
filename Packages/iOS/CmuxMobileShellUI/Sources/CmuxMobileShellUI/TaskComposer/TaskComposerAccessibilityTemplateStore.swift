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
    private var draft: MobileTaskComposerDraft?

    func listTemplates() -> [MobileTaskTemplate] {
        templates
    }

    func addTemplate(_ template: MobileTaskTemplate) {
        templates.append(template)
    }

    func updateTemplate(_ template: MobileTaskTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
    }

    func deleteTemplates(ids: Set<MobileTaskTemplate.ID>) {
        templates.removeAll { ids.contains($0.id) }
        if let selectedID = selectedTemplateID, ids.contains(selectedID) {
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

    func composerDraft() -> MobileTaskComposerDraft? {
        draft
    }

    func setComposerDraft(_ draft: MobileTaskComposerDraft?) {
        self.draft = draft
    }

    func clearAllUserData() {
        templates.removeAll()
        selectedTemplateID = nil
        selectedMacDeviceID = nil
        directoriesByMacDeviceID.removeAll()
        recentsByMacDeviceID.removeAll()
        draft = nil
    }
}
#endif
