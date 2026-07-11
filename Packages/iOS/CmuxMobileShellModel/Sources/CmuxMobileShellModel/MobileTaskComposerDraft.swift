public import Foundation

/// Stable identity for one logical task submission.
///
/// A retry reuses the same identity. Any edit that changes the requested task
/// rotates it so the Mac cannot mistake a new request for the previous one.
public struct MobileTaskSubmissionIdentity: Equatable, Sendable {
    /// Identity sent with `workspace.create`.
    public private(set) var id: UUID

    /// Creates an identity, restoring `id` for a retry when one exists.
    public init(id: UUID = UUID()) {
        self.id = id
    }

    /// Starts a distinct logical submission after composer input changes.
    public mutating func rotate() {
        id = UUID()
    }
}

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
