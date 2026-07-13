public import Foundation

/// The restorable, unsent state of the mobile task composer.
public struct MobileTaskComposerDraft: Codable, Equatable, Sendable {
    /// Prompt text exactly as entered by the user.
    public var prompt: String
    /// Selected template, validated against current templates when restored.
    public var templateID: MobileTaskTemplate.ID?
    /// Selected Mac, validated against current paired Macs when restored.
    public var macDeviceID: String?
    /// Working directory exactly as entered by the user.
    public var directory: String
    /// Whether the user replaced the suggested directory.
    public var didEditDirectory: Bool
    /// Stable identity for retrying this logical task creation without duplication.
    public var operationID: UUID?

    /// Creates a restorable composer draft.
    public init(
        prompt: String,
        templateID: MobileTaskTemplate.ID?,
        macDeviceID: String?,
        directory: String,
        didEditDirectory: Bool,
        operationID: UUID? = nil
    ) {
        self.prompt = prompt
        self.templateID = templateID
        self.macDeviceID = macDeviceID
        self.directory = directory
        self.didEditDirectory = didEditDirectory
        self.operationID = operationID
    }
}
