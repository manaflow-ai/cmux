#if os(iOS) && DEBUG
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport

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

    func deleteTemplate(id: MobileTaskTemplate.ID) {
        templates.removeAll { $0.id == id }
        if selectedTemplateID == id {
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
        draft = nil
    }
}
#endif
