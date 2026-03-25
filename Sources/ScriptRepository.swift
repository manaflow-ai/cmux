import Foundation

/// Manages startup script files stored in `~/.config/cmux/scripts/`.
/// Each script is a `.sh` file. The filename (without extension) is the script name.
final class ScriptRepository: ScriptRepositoryProtocol {

    let directory: URL

    /// Default script repository at `~/.config/cmux/scripts/`.
    static let shared = ScriptRepository(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/scripts")
    )

    init(directory: URL) {
        self.directory = directory
    }

    /// Lists all available script names (filenames without `.sh` extension).
    func listScripts() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents
            .filter { $0.pathExtension == "sh" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Returns the contents of a script, or nil if not found.
    func getScript(named name: String) -> String? {
        guard let safeName = try? NameSanitizer.sanitize(name) else { return nil }
        let path = directory.appendingPathComponent("\(safeName).sh")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// Saves or updates a script file. Creates the directory if needed.
    func saveScript(named name: String, content: String) throws {
        let safeName = try NameSanitizer.sanitize(name)
        try ensureDirectoryExists()
        let path = directory.appendingPathComponent("\(safeName).sh")
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Deletes a script file.
    func deleteScript(named name: String) throws {
        let safeName = try NameSanitizer.sanitize(name)
        let path = directory.appendingPathComponent("\(safeName).sh")
        try FileManager.default.removeItem(at: path)
    }

    /// Returns true if a script with the given name exists.
    func hasScript(named name: String) -> Bool {
        guard let safeName = try? NameSanitizer.sanitize(name) else { return false }
        let path = directory.appendingPathComponent("\(safeName).sh")
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Seeds default scripts on first use. Only writes files that don't already exist.
    func seedDefaultScripts() {
        for (name, content) in Self.defaultScripts {
            guard !hasScript(named: name) else { continue }
            try? saveScript(named: name, content: content)
        }
    }

    // MARK: - Default Script Definitions

    static let defaultScripts: [(name: String, content: String)] = [
        (
            name: "Builder",
            content: """
            #!/bin/bash
            # Builder: Start Claude Code in Builder/Foreman mode
            cd "$CMUX_FOLDER"
            claude --model sonnet "You are a BUILDER session. Read CLAUDE.md. You are the Foreman (read agents/foreman.md). Present: (1) Current project state, (2) Available phases/tasks. Ask what to build."
            """
        ),
        (
            name: "Fixer",
            content: """
            #!/bin/bash
            # Fixer: Start Claude Code in Fixer/Debugging mode
            cd "$CMUX_FOLDER"
            claude --model opus "You are a FIXER session. Read CLAUDE.md. You are the Foreman (read agents/foreman.md) in debugging/fixing mode. Ask me to describe the problem."
            """
        ),
        (
            name: "Claude",
            content: """
            #!/bin/bash
            # Claude: Start a plain Claude Code session
            cd "$CMUX_FOLDER"
            claude
            """
        ),
        (
            name: "Codex",
            content: """
            #!/bin/bash
            # Codex: Start Codex in the workspace folder
            cd "$CMUX_FOLDER"
            codex
            """
        ),
    ]

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
