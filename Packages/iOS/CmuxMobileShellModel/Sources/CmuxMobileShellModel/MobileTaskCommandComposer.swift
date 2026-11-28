import Foundation

/// Composes task startup parameters without interpreting user-authored shell source.
public struct MobileTaskCommandComposer: Sendable {
    /// Creates a command composer.
    public init() {}

    /// Preserves a nonblank template command byte-for-byte unless a model is
    /// explicitly selected, then inserts only its provider-specific model flag.
    /// Supplies the trimmed task prompt through `CMUX_TASK_PROMPT`. Attachment
    /// paths are exposed through `CMUX_TASK_ATTACHMENTS` and appended to the
    /// prompt for agent templates. Blank commands open a plain shell and
    /// intentionally receive no startup environment.
    /// - Parameters:
    ///   - template: The selected task template.
    ///   - prompt: User-entered task prompt.
    ///   - modelID: Optional CLI model identifier to apply to a known provider.
    ///   - effortID: Optional effort reported by the selected exact model.
    ///   - attachmentPaths: Absolute Mac paths produced by attachment uploads.
    /// - Returns: The command, environment, and prompt-derived title.
    public func compose(
        template: MobileTaskTemplate,
        prompt rawPrompt: String,
        modelID: String? = nil,
        effortID: String? = nil,
        attachmentPaths: [String] = []
    ) -> MobileTaskComposition {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = Self.taskTitle(from: prompt)
        guard !template.isPlainShell else {
            return MobileTaskComposition(initialCommand: nil, initialEnv: [:], title: title)
        }
        let initialCommand: String
        if let provider = MobileTaskAgentProvider(command: template.command) {
            let commandWithModel = modelID.map {
                provider.command(applying: $0, to: template.command)
            } ?? template.command
            initialCommand = effortID.map {
                provider.command(applyingEffort: $0, to: commandWithModel)
            } ?? commandWithModel
        } else {
            initialCommand = template.command
        }
        let composition = MobileTaskComposition(
            initialCommand: initialCommand,
            initialEnv: ["CMUX_TASK_PROMPT": prompt],
            title: title
        )
        return addingAttachmentPaths(attachmentPaths, to: composition)
    }

    /// Adds uploaded Mac paths to an already captured task composition.
    ///
    /// This is used after uploads finish so request snapshots can preserve the
    /// exact command captured before the first suspension.
    ///
    /// - Parameters:
    ///   - attachmentPaths: Absolute paths returned by the Mac.
    ///   - composition: Previously captured task composition.
    /// - Returns: The composition augmented with attachment environment values.
    public func addingAttachmentPaths(
        _ attachmentPaths: [String],
        to composition: MobileTaskComposition
    ) -> MobileTaskComposition {
        guard !attachmentPaths.isEmpty, composition.initialCommand != nil else {
            return composition
        }
        let pathList = attachmentPaths.joined(separator: "\n")
        let prompt = composition.initialEnv["CMUX_TASK_PROMPT"] ?? ""
        let promptSuffix = attachmentPaths
            .map { "- \($0)" }
            .joined(separator: "\n")
        var result = composition
        result.initialEnv["CMUX_TASK_ATTACHMENTS"] = pathList
        result.initialEnv["CMUX_TASK_PROMPT"] =
            prompt
            + "\n\nAttached files (absolute paths on this machine):\n"
            + promptSuffix
        return result
    }

    /// The suggested workspace title for a task prompt: its first line, capped
    /// at 60 characters. Static (not file-scope): the package conventions lint
    /// forbids free functions in iOS package sources.
    private static func taskTitle(from prompt: String) -> String? {
        guard let firstLine = prompt.split(separator: "\n", omittingEmptySubsequences: false).first,
              !firstLine.isEmpty else {
            return nil
        }
        return String(firstLine.prefix(60))
    }
}
