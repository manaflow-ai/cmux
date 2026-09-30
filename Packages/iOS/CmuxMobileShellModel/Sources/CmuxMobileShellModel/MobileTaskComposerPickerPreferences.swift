public import Foundation

/// Last picker choices for one paired Mac, independent of saved task drafts.
public nonisolated struct MobileTaskComposerPickerPreferences: Codable, Equatable, Sendable {
    public var templateID: MobileTaskTemplate.ID
    /// Preserve the selected model's labels and efforts through a cold cache.
    public var model: MobileTaskAgentModel?
    /// Default remains an implicit model selection, with its own effort choices.
    public var defaultModel: MobileTaskAgentModel?
    public var effortID: String?
    public var directory: String
    public var didEditDirectory: Bool
    public var workspaceGroupID: MobileWorkspaceGroupPreview.ID?

    public init(
        templateID: MobileTaskTemplate.ID,
        model: MobileTaskAgentModel?,
        defaultModel: MobileTaskAgentModel?,
        effortID: String?,
        directory: String,
        didEditDirectory: Bool,
        workspaceGroupID: MobileWorkspaceGroupPreview.ID?
    ) {
        self.templateID = templateID
        self.model = model
        self.defaultModel = defaultModel
        self.effortID = effortID
        self.directory = directory
        self.didEditDirectory = didEditDirectory
        self.workspaceGroupID = workspaceGroupID
    }
}
