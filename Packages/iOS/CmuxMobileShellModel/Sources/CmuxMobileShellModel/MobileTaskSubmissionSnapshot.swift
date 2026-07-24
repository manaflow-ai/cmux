public import Foundation

/// Immutable inputs and derived command for one task-composer submission.
///
/// The composer captures this value before its first suspension so a late RPC
/// result cannot settle against template, Mac, prompt, workspace-name, or
/// directory edits that were not part of the sent request.
public struct MobileTaskSubmissionSnapshot: Equatable, Sendable {
    /// Identifier of the task template selected when submission began.
    public let templateID: MobileTaskTemplate.ID
    /// Identifier of the Mac targeted by the captured submission.
    public let macDeviceID: String
    /// Unmodified prompt text captured from the composer.
    public let prompt: String
    /// Optional CLI model identifier captured from the composer.
    public let modelID: String?
    /// Optional workspace name exactly as entered in the composer.
    public let workspaceName: String
    /// Workspace name with surrounding whitespace removed.
    public let trimmedWorkspaceName: String
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

    /// Explicit workspace name, falling back to the prompt-derived title.
    public var workspaceTitle: String? {
        trimmedWorkspaceName.isEmpty ? composition.title : trimmedWorkspaceName
    }

    /// Captures immutable inputs and derives the command for one submission.
    ///
    /// - Parameters:
    ///   - template: Task template selected when submission begins.
    ///   - prompt: Prompt text to compose into the template command.
    ///   - modelID: Optional CLI model identifier to apply to the command.
    ///   - macDeviceID: Identifier of the Mac that should create the task.
    ///   - directory: Working-directory text shown in the composer.
    ///   - workspaceName: Optional workspace name shown in the composer.
    ///   - didEditDirectory: Whether the user changed the suggested directory.
    ///   - operationID: Stable idempotency key for submission retries.
    public init(
        template: MobileTaskTemplate,
        prompt: String,
        modelID: String? = nil,
        macDeviceID: String,
        directory: String,
        workspaceName: String = "",
        didEditDirectory: Bool,
        operationID: UUID
    ) {
        self.templateID = template.id
        self.macDeviceID = macDeviceID
        self.prompt = prompt
        self.modelID = modelID
        self.workspaceName = workspaceName
        self.trimmedWorkspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.directory = directory
        self.trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        self.didEditDirectory = didEditDirectory
        self.operationID = operationID
        self.composition = MobileTaskCommandComposer().compose(
            template: template,
            prompt: prompt,
            modelID: modelID
        )
    }

    /// Whether both snapshots produce the same `workspace.create` request.
    ///
    /// Template identity, presentation metadata, directory edit provenance,
    /// and operation identity are excluded because the Mac
    /// receives only the selected Mac, effective title, composed command and
    /// environment, and trimmed effective working directory.
    public func isRequestEquivalent(to other: MobileTaskSubmissionSnapshot) -> Bool {
        Self.hasEqualUTF8(macDeviceID, other.macDeviceID)
            && Self.hasEqualUTF8(composition.initialCommand, other.composition.initialCommand)
            && Self.hasEqualUTF8(composition.initialEnv, other.composition.initialEnv)
            && Self.hasEqualUTF8(workspaceTitle, other.workspaceTitle)
            && Self.hasEqualUTF8(trimmedDirectory, other.trimmedDirectory)
    }

    /// Rebinds an already-composed request to its resolved idempotency key.
    /// Swift value storage keeps this copy O(1); it does not trim, compose, or
    /// scan the request strings again.
    public func withOperationID(_ operationID: UUID) -> MobileTaskSubmissionSnapshot {
        MobileTaskSubmissionSnapshot(
            templateID: templateID,
            macDeviceID: macDeviceID,
            prompt: prompt,
            modelID: modelID,
            workspaceName: workspaceName,
            directory: directory,
            didEditDirectory: didEditDirectory,
            operationID: operationID,
            composition: composition,
            trimmedWorkspaceName: trimmedWorkspaceName,
            trimmedDirectory: trimmedDirectory
        )
    }

    private static func hasEqualUTF8(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func hasEqualUTF8(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            hasEqualUTF8(lhs, rhs)
        case (nil, nil):
            true
        default:
            false
        }
    }

    private static func hasEqualUTF8(
        _ lhs: [String: String],
        _ rhs: [String: String]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { lhsEntry in
            rhs.contains { rhsEntry in
                hasEqualUTF8(lhsEntry.key, rhsEntry.key)
                    && hasEqualUTF8(lhsEntry.value, rhsEntry.value)
            }
        }
    }

    /// Draft restored after interruption or a failed submission.
    public var draft: MobileTaskComposerDraft {
        MobileTaskComposerDraft(
            prompt: prompt,
            modelID: modelID,
            templateID: templateID,
            macDeviceID: macDeviceID.isEmpty ? nil : macDeviceID,
            directory: directory,
            didEditDirectory: didEditDirectory,
            workspaceName: workspaceName.isEmpty ? nil : workspaceName,
            operationID: operationID
        )
    }

    private init(
        templateID: MobileTaskTemplate.ID,
        macDeviceID: String,
        prompt: String,
        modelID: String?,
        workspaceName: String,
        directory: String,
        didEditDirectory: Bool,
        operationID: UUID,
        composition: MobileTaskComposition,
        trimmedWorkspaceName: String,
        trimmedDirectory: String
    ) {
        self.templateID = templateID
        self.macDeviceID = macDeviceID
        self.prompt = prompt
        self.modelID = modelID
        self.workspaceName = workspaceName
        self.trimmedWorkspaceName = trimmedWorkspaceName
        self.directory = directory
        self.trimmedDirectory = trimmedDirectory
        self.didEditDirectory = didEditDirectory
        self.operationID = operationID
        self.composition = composition
    }
}
