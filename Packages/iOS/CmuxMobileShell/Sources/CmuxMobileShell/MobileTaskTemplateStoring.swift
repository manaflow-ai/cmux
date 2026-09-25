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
    /// Returns every unsent task-composer draft, newest first.
    func composerDrafts() -> [MobileTaskComposerSavedDraft]
    /// Inserts or replaces one draft by its stable id and promotes it to the
    /// front of the collection.
    func saveComposerDraft(_ draft: MobileTaskComposerSavedDraft)
    /// Deletes the drafts with the provided ids in one persistence update,
    /// including any preserved attachment files they own.
    func deleteComposerDrafts(ids: Set<UUID>)
    /// Copies staged attachment bytes into draft-owned storage and returns
    /// the stable relative path, reusing an existing copy of the same
    /// attachment instead of copying again.
    func persistComposerAttachmentFile(
        draftID: UUID,
        attachmentID: UUID,
        preferredExtension: String,
        from sourceURL: URL
    ) throws -> String
    /// Returns the location of preserved attachment bytes, or `nil` when the
    /// path is invalid or the file no longer exists.
    func composerAttachmentFileURL(relativePath: String) -> URL?
    /// Removes all templates and composer state owned by the signed-out user.
    func clearAllUserData()
}

public extension MobileTaskTemplateStoring {
    /// Deletes one template.
    func deleteTemplate(id: MobileTaskTemplate.ID) {
        deleteTemplates(ids: [id])
    }

    /// Returns the saved draft with this id, if it still exists.
    func composerDraft(id: UUID) -> MobileTaskComposerSavedDraft? {
        composerDrafts().first { $0.id == id }
    }
}
