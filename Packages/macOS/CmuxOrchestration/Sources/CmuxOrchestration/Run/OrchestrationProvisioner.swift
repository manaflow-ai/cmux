import Foundation

/// Provisioning failure with a CLI/notification-ready message.
public struct OrchestrationProvisionError: Error, Sendable, Hashable, CustomStringConvertible {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Executes one workspace plan's provisioning: materializes the workspace
/// directory per the substrate (git worktree, fresh clone, or the template's
/// provision script) and writes the planned files (rendered prompt).
///
/// This is the only place template-authored code (script substrate) ever
/// runs, and it runs strictly at run time — never at install time — after
/// the trust summary has been confirmed.
public struct OrchestrationProvisioner: Sendable {
    private let fileSystem: any OrchestrationFileSystem
    private let processRunner: any OrchestrationProcessRunner

    public init(
        fileSystem: any OrchestrationFileSystem = DefaultOrchestrationFileSystem(),
        processRunner: any OrchestrationProcessRunner = DefaultOrchestrationProcessRunner()
    ) {
        self.fileSystem = fileSystem
        self.processRunner = processRunner
    }

    public func provision(_ workspace: OrchestrationWorkspacePlan) throws {
        let parent = (workspace.directory as NSString).deletingLastPathComponent
        if !fileSystem.directoryExists(atPath: parent) {
            try fileSystem.createDirectory(atPath: parent)
        }
        guard !fileSystem.directoryExists(atPath: workspace.directory),
              !fileSystem.fileExists(atPath: workspace.directory)
        else {
            throw OrchestrationProvisionError(
                message: "Workspace directory already exists: \(workspace.directory)"
            )
        }

        switch workspace.provision {
        case .gitWorktree(let repoRoot, let branch):
            try runOrThrow(
                "git",
                ["-C", repoRoot, "worktree", "add", "-b", branch, workspace.directory],
                context: "git worktree add"
            )
        case .gitClone(let repoRoot, let branch):
            try runOrThrow(
                "git",
                ["clone", "--", repoRoot, workspace.directory],
                context: "git clone"
            )
            try runOrThrow(
                "git",
                ["-C", workspace.directory, "checkout", "-b", branch],
                context: "git checkout -b"
            )
        case .script(let scriptPath):
            guard fileSystem.fileExists(atPath: scriptPath) else {
                throw OrchestrationProvisionError(message: "Provision script missing: \(scriptPath)")
            }
            let result: OrchestrationProcessResult
            do {
                result = try processRunner.run(
                    executable: scriptPath,
                    arguments: [workspace.directory],
                    currentDirectory: parent,
                    environment: workspace.env
                )
            } catch {
                throw OrchestrationProvisionError(
                    message: "Provision script failed to launch: \(error.localizedDescription)"
                )
            }
            guard result.succeeded else {
                throw OrchestrationProvisionError(
                    message: "Provision script exited \(result.exitCode): \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            // The script owns directory creation (it may mount, clone, or
            // symlink); require that it actually produced the directory.
            guard fileSystem.directoryExists(atPath: workspace.directory) else {
                throw OrchestrationProvisionError(
                    message: "Provision script did not create \(workspace.directory)"
                )
            }
        }

        for file in workspace.filesToWrite {
            let absolute = workspace.directory + "/" + file.relativePath
            let fileParent = (absolute as NSString).deletingLastPathComponent
            if !fileSystem.directoryExists(atPath: fileParent) {
                try fileSystem.createDirectory(atPath: fileParent)
            }
            try fileSystem.writeData(Data(file.contents.utf8), atPath: absolute)
        }
    }

    private func runOrThrow(_ executable: String, _ arguments: [String], context: String) throws {
        let result: OrchestrationProcessResult
        do {
            result = try processRunner.run(
                executable: executable,
                arguments: arguments,
                currentDirectory: nil,
                environment: nil
            )
        } catch {
            throw OrchestrationProvisionError(
                message: "\(context) failed to launch: \(error.localizedDescription)"
            )
        }
        guard result.succeeded else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OrchestrationProvisionError(
                message: "\(context) exited \(result.exitCode)" + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
    }
}
