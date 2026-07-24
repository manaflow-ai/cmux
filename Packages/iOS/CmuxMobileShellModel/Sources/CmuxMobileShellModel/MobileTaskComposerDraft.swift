public import Foundation

/// The restorable, unsent state of the mobile task composer.
public struct MobileTaskComposerDraft: Codable, Equatable, Sendable {
    /// Prompt text exactly as entered by the user.
    public var prompt: String
    /// Optional CLI model identifier selected for the task template.
    public var modelID: String?
    /// Selected template, validated against current templates when restored.
    public var templateID: MobileTaskTemplate.ID?
    /// Selected Mac, validated against current paired Macs when restored.
    public var macDeviceID: String?
    /// Working directory exactly as entered by the user.
    public var directory: String
    /// Whether the user replaced the suggested directory.
    public var didEditDirectory: Bool
    /// Optional workspace name exactly as entered by the user.
    public var workspaceName: String?
    /// Stable identity for retrying this logical task creation without duplication.
    public var operationID: UUID?
    /// Accepted identity awaiting an explicit refresh before this draft may be
    /// started with a fresh operation ID.
    public var completedOperationID: UUID?

    /// Creates a restorable composer draft.
    public init(
        prompt: String,
        modelID: String? = nil,
        templateID: MobileTaskTemplate.ID?,
        macDeviceID: String?,
        directory: String,
        didEditDirectory: Bool,
        workspaceName: String? = nil,
        operationID: UUID? = nil,
        completedOperationID: UUID? = nil
    ) {
        self.prompt = prompt
        self.modelID = modelID
        self.templateID = templateID
        self.macDeviceID = macDeviceID
        self.directory = directory
        self.didEditDirectory = didEditDirectory
        self.workspaceName = workspaceName
        self.operationID = operationID
        self.completedOperationID = completedOperationID
    }

    /// Selects a template and adopts its suggested directory until the user
    /// has explicitly edited the directory field.
    /// - Parameters:
    ///   - id: Identifier of the newly selected template.
    ///   - suggestedDirectory: Directory suggested by that template and Mac.
    public mutating func selectTemplate(
        id: MobileTaskTemplate.ID,
        suggestedDirectory: String
    ) {
        templateID = id
        guard !didEditDirectory else { return }
        directory = suggestedDirectory
    }
}
