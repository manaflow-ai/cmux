import Foundation

/// A node in the template tree. Represents a workspace with optional children.
struct TemplateNode: Equatable {
    let title: String
    let color: String?
    let command: String?
    let children: [TemplateNode]
}

/// A parsed workspace template with a root node containing children.
struct WorkspaceTemplate: Equatable {
    let root: TemplateNode
}

/// Legacy tab definition for backward compatibility with old `tabs:` format.
struct TemplateTabDefinition: Equatable {
    let title: String
    let startupScript: String?
}

/// Manages workspace template files stored in `~/.config/cmux/templates/`.
/// Each template is a `.yaml` file with a `root:` tree of workspace definitions.
final class TemplateRepository {

    let directory: URL

    /// Default template repository at `~/.config/cmux/templates/`.
    static let shared = TemplateRepository(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/templates")
    )

    init(directory: URL) {
        self.directory = directory
    }

    /// Lists all available template names (filenames without `.yaml` extension).
    func listTemplates() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "yaml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Parses and returns a template by name.
    func getTemplate(named name: String) throws -> WorkspaceTemplate {
        let path = directory.appendingPathComponent("\(name).yaml")
        let content = try String(contentsOf: path, encoding: .utf8)
        return try TemplateYamlParser.parse(content)
    }

    /// Returns the raw YAML string for a template, or nil if not found.
    func rawYaml(named name: String) -> String? {
        let path = directory.appendingPathComponent("\(name).yaml")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// Saves a template definition to a file. Creates the directory if needed.
    func saveTemplate(named name: String, template: WorkspaceTemplate) throws {
        try ensureDirectoryExists()
        let yaml = TemplateYamlParser.serialize(template)
        let path = directory.appendingPathComponent("\(name).yaml")
        try yaml.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Saves raw YAML content as a template file. Creates the directory if needed.
    func saveTemplate(named name: String, rawYaml: String) throws {
        try ensureDirectoryExists()
        let path = directory.appendingPathComponent("\(name).yaml")
        try rawYaml.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Deletes a template file.
    func deleteTemplate(named name: String) throws {
        let path = directory.appendingPathComponent("\(name).yaml")
        try FileManager.default.removeItem(at: path)
    }

    /// Returns true if a template with the given name exists.
    func hasTemplate(named name: String) -> Bool {
        let path = directory.appendingPathComponent("\(name).yaml")
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Seeds default templates on first use. Only writes files that don't already exist.
    func seedDefaultTemplates() {
        for (name, content) in Self.defaultTemplates {
            guard !hasTemplate(named: name) else { continue }
            try? ensureDirectoryExists()
            let path = directory.appendingPathComponent("\(name).yaml")
            try? content.write(to: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Default Template Definitions

    // swiftlint:disable line_length
    static let defaultTemplates: [(name: String, content: String)] = [
        (
            name: "AI Dev",
            content: """
            root:
              title: Terminal
              children:
                - title: Builder
                  color: "#00CC00"
                  command: |
                    claude --model sonnet "You are a BUILDER session — the Session Role section in CLAUDE.md does not apply to you. Use the Read tool (not bash) to read CLAUDE.md. You are the Foreman (use Read tool on agents/foreman.md). Start a new building session. Use Glob and Read to find and read any project spec. Use Glob to check for STATE.md or CONTINUE.md. IMPORTANT: use Read/Glob/Grep tools for all file exploration — never use compound bash commands. Present: (1) Current project state, (2) Available phases/tasks. Ask what to build."
                - title: Fixer
                  color: "#FF0000"
                  command: |
                    claude --model opus "You are a FIXER session — the Session Role section in CLAUDE.md does not apply to you. Use the Read tool (not bash) to read CLAUDE.md. You are the Foreman (use Read tool on agents/foreman.md) in debugging/fixing mode. Use Glob to explore the project structure. Use 'git log --oneline -10' and 'git diff' (single simple commands, never compound) to check recent changes. IMPORTANT: use Read/Glob/Grep tools for all file exploration — never use compound bash commands. Ask me to describe the problem. When I do, use the 'Give me problem status' format: (1) Current bad behavior, (2) Log results, (3) What you think is wrong, (4) Proposed solution. Fix one thing at a time."
                - title: Codex
                  color: "#9900FF"
                  command: codex --approval-mode full-auto
            """
        ),
        (
            name: "Builder",
            content: """
            root:
              title: Terminal
              children:
                - title: Builder
                  color: "#00CC00"
                  command: |
                    claude --model sonnet "You are a BUILDER session — the Session Role section in CLAUDE.md does not apply to you. Use the Read tool (not bash) to read CLAUDE.md. You are the Foreman (use Read tool on agents/foreman.md). Start a new building session. Use Glob and Read to find and read any project spec. Use Glob to check for STATE.md or CONTINUE.md. IMPORTANT: use Read/Glob/Grep tools for all file exploration — never use compound bash commands. Present: (1) Current project state, (2) Available phases/tasks. Ask what to build."
            """
        ),
        (
            name: "Fixer",
            content: """
            root:
              title: Terminal
              children:
                - title: Fixer
                  color: "#FF0000"
                  command: |
                    claude --model opus "You are a FIXER session — the Session Role section in CLAUDE.md does not apply to you. Use the Read tool (not bash) to read CLAUDE.md. You are the Foreman (use Read tool on agents/foreman.md) in debugging/fixing mode. Use Glob to explore the project structure. Use 'git log --oneline -10' and 'git diff' (single simple commands, never compound) to check recent changes. IMPORTANT: use Read/Glob/Grep tools for all file exploration — never use compound bash commands. Ask me to describe the problem. When I do, use the 'Give me problem status' format: (1) Current bad behavior, (2) Log results, (3) What you think is wrong, (4) Proposed solution. Fix one thing at a time."
            """
        ),
    ]
    // swiftlint:enable line_length

    // MARK: - Private

    private func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}
