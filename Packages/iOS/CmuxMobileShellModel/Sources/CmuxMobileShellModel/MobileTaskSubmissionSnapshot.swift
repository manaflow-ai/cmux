public import Foundation

/// Immutable inputs and derived command for one task-composer submission.
///
/// The composer captures this value before its first suspension so a late RPC
/// result cannot settle against template, Mac, prompt, workspace-name, or
/// directory and group edits that were not part of the sent request.
public struct MobileTaskSubmissionSnapshot: Equatable, Sendable {
    /// Identifier of the task template selected when submission began.
    public let templateID: MobileTaskTemplate.ID
    /// Identifier of the Mac targeted by the captured submission.
    public let macDeviceID: String
    /// Paired app instance targeted by the captured submission, or `nil` for
    /// legacy device-level routing.
    public let macInstanceTag: String?
    /// Unmodified prompt text captured from the composer.
    public let prompt: String
    /// Optional CLI model identifier captured from the composer.
    public let modelID: String?
    /// Optional model-specific effort captured from the composer.
    public let effortID: String?
    /// Optional workspace name exactly as entered in the composer.
    public let workspaceName: String
    /// Workspace name with surrounding whitespace removed.
    public let trimmedWorkspaceName: String
    /// Selected workspace group, or `nil` for an ungrouped workspace.
    public let workspaceGroupID: MobileWorkspaceGroupPreview.ID?
    /// Unmodified working-directory text captured from the composer.
    public let directory: String
    /// Working directory with surrounding whitespace removed for validation.
    public let trimmedDirectory: String
    /// Whether the user edited the template's suggested working directory.
    public let didEditDirectory: Bool
    /// Value-only attachment identities captured for request equivalence.
    public let attachments: [MobileTaskSubmissionAttachment]
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
    ///   - effortID: Optional effort reported by the selected exact model.
    ///   - macDeviceID: Identifier of the Mac that should create the task.
    ///   - macInstanceTag: Exact paired app instance to target, or `nil`.
    ///   - directory: Working-directory text shown in the composer.
    ///   - workspaceName: Optional workspace name shown in the composer.
    ///   - workspaceGroupID: Optional destination workspace group.
    ///   - didEditDirectory: Whether the user changed the suggested directory.
    ///   - attachments: Attachment upload identifiers and staged byte counts.
    ///   - operationID: Stable idempotency key for submission retries.
    public init(
        template: MobileTaskTemplate,
        prompt: String,
        modelID: String? = nil,
        effortID: String? = nil,
        macDeviceID: String,
        macInstanceTag: String? = nil,
        directory: String,
        workspaceName: String = "",
        workspaceGroupID: MobileWorkspaceGroupPreview.ID? = nil,
        didEditDirectory: Bool,
        attachments: [MobileTaskSubmissionAttachment] = [],
        operationID: UUID
    ) {
        self.templateID = template.id
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.prompt = prompt
        self.modelID = modelID
        self.effortID = effortID
        self.workspaceName = workspaceName
        self.trimmedWorkspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspaceGroupID = workspaceGroupID
        self.directory = directory
        self.trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        self.didEditDirectory = didEditDirectory
        self.attachments = attachments
        self.operationID = operationID
        self.composition = MobileTaskCommandComposer().compose(
            template: template,
            prompt: prompt,
            modelID: modelID,
            effortID: effortID
        )
    }

    /// Whether both snapshots produce the same `workspace.create` request.
    ///
    /// Template identity, presentation metadata, directory edit provenance,
    /// and operation identity are excluded because the Mac
    /// receives only the selected Mac, effective title, composed command and
    /// environment, trimmed effective working directory, and destination group.
    public func isRequestEquivalent(to other: MobileTaskSubmissionSnapshot) -> Bool {
        Self.hasEqualUTF8(macDeviceID, other.macDeviceID)
            && Self.hasEqualUTF8(macInstanceTag, other.macInstanceTag)
            && Self.hasEqualUTF8(composition.initialCommand, other.composition.initialCommand)
            && Self.hasEqualUTF8(composition.initialEnv, other.composition.initialEnv)
            && Self.hasEqualUTF8(workspaceTitle, other.workspaceTitle)
            && Self.hasEqualUTF8(workspaceGroupID?.rawValue, other.workspaceGroupID?.rawValue)
            && Self.hasEqualUTF8(trimmedDirectory, other.trimmedDirectory)
            && attachments == other.attachments
    }

    /// Rebinds an already-composed request to its resolved idempotency key.
    /// Swift value storage keeps this copy O(1); it does not trim, compose, or
    /// scan the request strings again.
    public func withOperationID(_ operationID: UUID) -> MobileTaskSubmissionSnapshot {
        MobileTaskSubmissionSnapshot(
            templateID: templateID,
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            prompt: prompt,
            modelID: modelID,
            effortID: effortID,
            workspaceName: workspaceName,
            workspaceGroupID: workspaceGroupID,
            directory: directory,
            didEditDirectory: didEditDirectory,
            attachments: attachments,
            operationID: operationID,
            composition: composition,
            trimmedWorkspaceName: trimmedWorkspaceName,
            trimmedDirectory: trimmedDirectory
        )
    }

    /// Applies absolute paths returned by attachment uploads to the captured composition.
    ///
    /// - Parameter attachmentPaths: Absolute Mac paths in attachment order.
    /// - Returns: A composition with attachment environment and prompt suffix.
    public func composition(attachmentPaths: [String]) -> MobileTaskComposition {
        MobileTaskCommandComposer().addingAttachmentPaths(
            attachmentPaths,
            to: composition
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
            effortID: effortID,
            templateID: templateID,
            macDeviceID: macDeviceID.isEmpty ? nil : macDeviceID,
            macInstanceTag: macDeviceID.isEmpty ? nil : macInstanceTag,
            directory: directory,
            didEditDirectory: didEditDirectory,
            workspaceName: workspaceName.isEmpty ? nil : workspaceName,
            workspaceGroupID: workspaceGroupID,
            operationID: operationID
        )
    }

    private init(
        templateID: MobileTaskTemplate.ID,
        macDeviceID: String,
        macInstanceTag: String?,
        prompt: String,
        modelID: String?,
        effortID: String?,
        workspaceName: String,
        workspaceGroupID: MobileWorkspaceGroupPreview.ID?,
        directory: String,
        didEditDirectory: Bool,
        attachments: [MobileTaskSubmissionAttachment],
        operationID: UUID,
        composition: MobileTaskComposition,
        trimmedWorkspaceName: String,
        trimmedDirectory: String
    ) {
        self.templateID = templateID
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.prompt = prompt
        self.modelID = modelID
        self.effortID = effortID
        self.workspaceName = workspaceName
        self.trimmedWorkspaceName = trimmedWorkspaceName
        self.workspaceGroupID = workspaceGroupID
        self.directory = directory
        self.trimmedDirectory = trimmedDirectory
        self.didEditDirectory = didEditDirectory
        self.attachments = attachments
        self.operationID = operationID
        self.composition = composition
    }
}
