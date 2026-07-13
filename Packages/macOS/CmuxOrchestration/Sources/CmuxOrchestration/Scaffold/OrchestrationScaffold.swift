import Foundation

/// Generates a starter template for `cmux orchestration init`: a small,
/// valid, worktree-substrate orchestration the author edits from there.
public struct OrchestrationScaffold: Sendable {
    private let fileSystem: any OrchestrationFileSystem

    public init(fileSystem: any OrchestrationFileSystem = DefaultOrchestrationFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Files created relative to the target directory.
    public static func files(name: String) -> [OrchestrationPlannedFile] {
        [
            OrchestrationPlannedFile(
                relativePath: OrchestrationManifest.manifestFileName,
                contents: manifestJSON(name: name)
            ),
            OrchestrationPlannedFile(relativePath: "WORKFLOW.md", contents: workflowMarkdown(name: name)),
            OrchestrationPlannedFile(relativePath: "prompts/task.md", contents: taskPrompt),
            OrchestrationPlannedFile(relativePath: "README.md", contents: readme(name: name)),
        ]
    }

    /// Scaffolds into `directory` (created if needed). Refuses to touch a
    /// directory that already contains an orchestration.json.
    public func scaffold(name: String, directory: String) throws {
        guard OrchestrationManifest.isValidName(name) else {
            throw OrchestrationManifestError(
                message: "'\(name)' is not a valid template name (lowercase letters, digits, hyphens)"
            )
        }
        let manifestPath = directory + "/" + OrchestrationManifest.manifestFileName
        if fileSystem.fileExists(atPath: manifestPath) {
            throw OrchestrationManifestError(
                message: "\(OrchestrationManifest.manifestFileName) already exists in \(directory)"
            )
        }
        for file in Self.files(name: name) {
            let absolute = directory + "/" + file.relativePath
            let parent = (absolute as NSString).deletingLastPathComponent
            if !fileSystem.directoryExists(atPath: parent) {
                try fileSystem.createDirectory(atPath: parent)
            }
            try fileSystem.writeData(Data(file.contents.utf8), atPath: absolute)
        }
    }

    private static func manifestJSON(name: String) -> String {
        """
        {
          "schemaVersion": 1,
          "name": "\(name)",
          "version": "0.1.0",
          "description": "Describe what this orchestration does",
          "parameters": [
            {
              "key": "repo_root",
              "prompt": "Absolute path of the repository tasks should work on",
              "type": "path"
            },
            {
              "key": "concurrency",
              "prompt": "Maximum simultaneous task workspaces",
              "type": "int",
              "default": 3
            }
          ],
          "substrate": { "kind": "worktree" },
          "agents": [
            {
              "id": "claude",
              "registryAgent": "claude",
              "command": "claude {{prompt}}"
            }
          ],
          "prompt": "prompts/task.md",
          "workflow": "WORKFLOW.md"
        }
        """
    }

    private static let taskPrompt = """
    You are working in {{workspace_dir}} on branch {{branch}}.

    Task:
    {{task}}

    Work autonomously. Commit your changes when done.
    """

    private static func workflowMarkdown(name: String) -> String {
        """
        # \(name) workflow

        Describe the work source, caps, and how agents should behave here.
        This file travels with the template and is shown by
        `cmux orchestration info \(name)`.
        """
    }

    private static func readme(name: String) -> String {
        """
        # \(name)

        A cmux orchestration template. Install with:

            cmux orchestration install <this-directory-or-git-url>

        Then run tasks:

            cmux orchestration run \(name) --task "something to do"

        Edit `orchestration.json`, `prompts/`, and `WORKFLOW.md` to shape the
        fleet. See the cmux orchestration docs for the format.
        """
    }
}
