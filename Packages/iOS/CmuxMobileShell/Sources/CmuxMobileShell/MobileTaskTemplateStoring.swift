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
    /// Deletes the template with `id`.
    func deleteTemplate(id: MobileTaskTemplate.ID)
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
}
