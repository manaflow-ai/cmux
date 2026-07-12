import Foundation

extension TerminalController {
    /// Returns the selected workspace's working-tree patch for the native iOS diff shell.
    @MainActor
    func v2MobileDiffLoad(params: [String: Any]) async -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager),
              let directory = workspace.resolvedWorkingDirectory() else {
            return .err(code: "not_found", message: "Workspace directory not found", data: nil)
        }
        let workspaceTitle = workspace.title
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try MobileWorkingTreeDiffLoader.load(directory: directory, title: workspaceTitle)
            }.value
            return .ok(document)
        } catch let error as MobileWorkingTreeDiffLoader.LoadError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch {
            return .err(code: "internal_error", message: "Failed to load workspace diff", data: nil)
        }
    }
}

enum MobileWorkingTreeDiffLoader {
    static let maximumPatchBytes = 6 * 1024 * 1024
    static let maximumUntrackedFiles = 200

    struct LoadError: Error {
        let code: String
        let message: String
    }

    nonisolated static func load(directory: String, title: String) throws -> [String: Any] {
        let repoResult = try runGit(["rev-parse", "--show-toplevel"], directory: directory)
        guard repoResult.status == 0,
              let repositoryRoot = String(data: repoResult.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !repositoryRoot.isEmpty else {
            throw LoadError(code: "not_found", message: "Workspace is not inside a Git repository")
        }

        let hasHead = (try runGit(["rev-parse", "--verify", "HEAD"], directory: repositoryRoot)).status == 0
        let trackedArguments = hasHead
            ? ["diff", "--no-ext-diff", "--binary", "HEAD", "--"]
            : ["diff", "--no-ext-diff", "--binary", "--"]
        let tracked = try runGit(trackedArguments, directory: repositoryRoot)
        guard tracked.status == 0 else {
            throw LoadError(code: "git_error", message: stderrMessage(tracked.stderr, fallback: "Git diff failed"))
        }

        var patch = tracked.stdout
        let untracked = try runGit(["ls-files", "--others", "--exclude-standard", "-z"], directory: repositoryRoot)
        guard untracked.status == 0 else {
            throw LoadError(code: "git_error", message: stderrMessage(untracked.stderr, fallback: "Could not list untracked files"))
        }
        let paths = untracked.stdout.split(separator: 0).prefix(maximumUntrackedFiles)
        for pathData in paths {
            guard let path = String(data: Data(pathData), encoding: .utf8), !path.isEmpty else { continue }
            let result = try runGit(["diff", "--no-index", "--binary", "--", "/dev/null", path], directory: repositoryRoot)
            guard result.status == 0 || result.status == 1 else {
                throw LoadError(code: "git_error", message: stderrMessage(result.stderr, fallback: "Could not diff untracked file"))
            }
            patch.append(result.stdout)
            guard patch.count <= maximumPatchBytes else {
                throw LoadError(code: "too_large", message: "Workspace diff is too large to send to this phone")
            }
        }

        guard patch.count <= maximumPatchBytes else {
            throw LoadError(code: "too_large", message: "Workspace diff is too large to send to this phone")
        }
        guard let patchText = String(data: patch, encoding: .utf8) else {
            throw LoadError(code: "invalid_data", message: "Workspace diff is not valid UTF-8")
        }
        return [
            "patch": patchText,
            "repository_root": repositoryRoot,
            "title": title,
        ]
    }

    private struct GitResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    nonisolated private static func runGit(_ arguments: [String], directory: String) throws -> GitResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw LoadError(code: "git_error", message: "Could not start Git")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(status: process.terminationStatus, stdout: output, stderr: errorOutput)
    }

    nonisolated private static func stderrMessage(_ data: Data, fallback: String) -> String {
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? fallback : String(message.prefix(1_024))
    }
}
