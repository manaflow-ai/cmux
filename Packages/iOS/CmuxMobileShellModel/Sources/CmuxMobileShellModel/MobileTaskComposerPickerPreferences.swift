public import Foundation

/// Last picker choices for one paired Mac, independent of saved task drafts.
public nonisolated struct MobileTaskComposerPickerPreferences: Codable, Equatable, Sendable {
    /// The last template selected for this Mac.
    public var templateID: MobileTaskTemplate.ID
    /// Preserve the selected model's labels and efforts through a cold cache.
    public var model: MobileTaskAgentModel?
    /// Default remains an implicit model selection, with its own effort choices.
    public var defaultModel: MobileTaskAgentModel?
    /// The last effort selected for the active model.
    public var effortID: String?
    /// The last directory selected for this Mac.
    public var directory: String
    /// Whether the directory came from an explicit user edit.
    public var didEditDirectory: Bool
    /// The last workspace group selected for this Mac.
    public var workspaceGroupID: MobileWorkspaceGroupPreview.ID?

    /// Creates the saved picker state for one paired Mac.
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
