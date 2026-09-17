public import CmuxMobileShellModel
public import Foundation

/// Device-local persistence for mobile task templates and composer defaults.
@MainActor
public protocol MobileTaskTemplateStoring: AnyObject {
    /// Returns all stored templates, seeding defaults on the first read.
    func listTemplates() -> [MobileTaskTemplate]
    /// Appends a template and persists the full list.
    func addTemplate(_ template: MobileTaskTemplate)
    /// Replaces an existing template with the same id.
    func updateTemplate(_ template: MobileTaskTemplate)
    /// Deletes the templates with the provided ids in one persistence update.
    func deleteTemplates(ids: Set<MobileTaskTemplate.ID>)
    /// Returns the last selected template id, if any.
    func lastTemplateID() -> MobileTaskTemplate.ID?
    /// Stores the last selected template id.
    func setLastTemplateID(_ id: MobileTaskTemplate.ID?)
    /// Returns the last selected Mac device id, if any.
    func lastMacDeviceID() -> String?
    /// Stores the last selected Mac device id.
    func setLastMacDeviceID(_ id: String?)
    /// Returns the last successful directory for one Mac.
    func lastDirectory(macDeviceID: String) -> String?
    /// Stores the last successful directory for one Mac.
    func setLastDirectory(_ directory: String?, macDeviceID: String)
    /// Returns bounded successful directory history for one Mac, newest first.
    func recentDirectories(macDeviceID: String) -> [MobileTaskRecentDirectory]
    /// Promotes one successful directory in the per-Mac history.
    func recordRecentDirectory(_ directory: String, macDeviceID: String, at date: Date)
    /// Returns the unsent task-composer draft, if one was saved.
    func composerDraft() -> MobileTaskComposerDraft?
    /// Stores or clears the unsent task-composer draft.
    func setComposerDraft(_ draft: MobileTaskComposerDraft?)
    /// Removes all templates and composer state owned by the signed-out user.
    func clearAllUserData()
}

public extension MobileTaskTemplateStoring {
    /// Deletes one template.
    func deleteTemplate(id: MobileTaskTemplate.ID) {
        deleteTemplates(ids: [id])
    }
}
