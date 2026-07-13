public import Foundation

/// Immutable inputs and derived command for one task-composer submission.
///
/// The composer captures this value before its first suspension so a late RPC
/// result cannot settle against template, Mac, prompt, or directory edits that
/// were not part of the sent request.
public struct MobileTaskSubmissionSnapshot: Equatable, Sendable {
    public let templateID: MobileTaskTemplate.ID
    public let macDeviceID: String
    public let prompt: String
    public let directory: String
    public let trimmedDirectory: String
    public let didEditDirectory: Bool
    public let operationID: UUID
    public let composition: MobileTaskComposition

    public init(
        template: MobileTaskTemplate,
        prompt: String,
        macDeviceID: String,
        directory: String,
        didEditDirectory: Bool,
        operationID: UUID
    ) {
        self.templateID = template.id
        self.macDeviceID = macDeviceID
        self.prompt = prompt
        self.directory = directory
        self.trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        self.didEditDirectory = didEditDirectory
        self.operationID = operationID
        self.composition = MobileTaskCommandComposer().compose(template: template, prompt: prompt)
    }

    /// Draft restored after interruption or a failed submission.
    public var draft: MobileTaskComposerDraft {
        MobileTaskComposerDraft(
            prompt: prompt,
            templateID: templateID,
            macDeviceID: macDeviceID.isEmpty ? nil : macDeviceID,
            directory: directory,
            didEditDirectory: didEditDirectory,
            operationID: operationID
        )
    }
}
