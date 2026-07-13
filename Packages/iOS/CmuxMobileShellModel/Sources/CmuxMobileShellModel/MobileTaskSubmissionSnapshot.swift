public import Foundation

/// Immutable inputs and derived command for one task-composer submission.
///
/// The composer captures this value before its first suspension so a late RPC
/// result cannot settle against template, Mac, prompt, or directory edits that
/// were not part of the sent request.
public struct MobileTaskSubmissionSnapshot: Equatable, Sendable {
    /// Identifier of the task template selected when submission began.
    public let templateID: MobileTaskTemplate.ID
    /// Identifier of the Mac targeted by the captured submission.
    public let macDeviceID: String
    /// Unmodified prompt text captured from the composer.
    public let prompt: String
    /// Unmodified working-directory text captured from the composer.
    public let directory: String
    /// Working directory with surrounding whitespace removed for validation.
    public let trimmedDirectory: String
    /// Whether the user edited the template's suggested working directory.
    public let didEditDirectory: Bool
    /// Stable idempotency key used for every attempt to submit this snapshot.
    public let operationID: UUID
    /// Command and environment derived from the captured template and prompt.
    public let composition: MobileTaskComposition

    /// Captures immutable inputs and derives the command for one submission.
    ///
    /// - Parameters:
    ///   - template: Task template selected when submission begins.
    ///   - prompt: Prompt text to compose into the template command.
    ///   - macDeviceID: Identifier of the Mac that should create the task.
    ///   - directory: Working-directory text shown in the composer.
    ///   - didEditDirectory: Whether the user changed the suggested directory.
    ///   - operationID: Stable idempotency key for submission retries.
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

    /// Whether both snapshots produce the same `workspace.create` request.
    ///
    /// Template identity and presentation metadata, raw whitespace, directory
    /// edit provenance, and operation identity are excluded because the Mac
    /// receives only the selected Mac, composed title/command/environment, and
    /// trimmed effective working directory.
    public func isRequestEquivalent(to other: MobileTaskSubmissionSnapshot) -> Bool {
        macDeviceID == other.macDeviceID
            && composition == other.composition
            && trimmedDirectory == other.trimmedDirectory
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
