/// Renders Fleet agent command templates.
public struct FleetPromptTemplate: Sendable {
    /// Creates a prompt template renderer.
    public init() {}

    /// Renders a shell command template for a task.
    ///
    /// Every string placeholder except `{{TASK_ID}}` is shell-quoted by the
    /// renderer, so templates must not add their own quotes around them.
    /// - Parameters:
    ///   - template: The agent command template.
    ///   - task: The task snapshot used for prompt placeholders.
    ///   - directory: The task working directory.
    ///   - branch: The task branch, when known.
    /// - Returns: The rendered command text.
    public func render(
        template: String,
        task: FleetTask,
        directory: String,
        branch: String?
    ) -> String {
        let prompt = task.body.isEmpty ? task.title : "\(task.title)\n\n\(task.body)"
        let replacements = [
            "{{PROMPT}}": shellQuoted(prompt),
            "{{TITLE}}": shellQuoted(task.title),
            "{{BODY}}": shellQuoted(task.body),
            "{{TASK_ID}}": task.id.rawValue,
            "{{DIR}}": shellQuoted(directory),
            "{{BRANCH}}": branch.map(shellQuoted) ?? "",
        ]
        var rendered = template
        for (placeholder, value) in replacements {
            rendered = rendered.replacingOccurrences(of: placeholder, with: value)
        }
        return rendered
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
