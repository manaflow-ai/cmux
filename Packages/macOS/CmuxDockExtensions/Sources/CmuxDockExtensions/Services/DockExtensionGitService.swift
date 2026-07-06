import Foundation

/// Git operations for extension installs: resolving a remote ref to a commit
/// SHA and materializing a detached checkout pinned at that SHA.
///
/// Uses `/usr/bin/git` (the macOS shim; a clear ``DockExtensionError/gitUnavailable(detail:)``
/// is raised when the Command Line Tools are missing) with terminal prompts
/// disabled — private repos fail cleanly instead of hanging on a credential
/// prompt.
public actor DockExtensionGitService {
    private let runner: DockExtensionProcessRunner
    private let gitExecutableURL: URL

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - runner: Subprocess runner (injectable for tests).
    ///   - gitExecutableURL: The git binary; defaults to `/usr/bin/git`.
    public init(
        runner: DockExtensionProcessRunner = DockExtensionProcessRunner(),
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git")
    ) {
        self.runner = runner
        self.gitExecutableURL = gitExecutableURL
    }

    /// Resolves `ref` (branch, tag, full SHA, or `nil` for the remote default
    /// branch) against a clone URL, returning the commit SHA to pin.
    public func resolveRemoteRevision(cloneURL: String, ref: String?) async throws -> String {
        if let ref, Self.isFullSha(ref) {
            return ref.lowercased()
        }
        var arguments = ["ls-remote", cloneURL]
        if let ref {
            arguments += ["refs/heads/\(ref)", "refs/tags/\(ref)", ref]
        } else {
            arguments.append("HEAD")
        }
        let result = try await runGit(arguments, operation: "ls-remote", timeout: .seconds(60))
        guard let sha = Self.pickRevision(from: result.standardOutput, ref: ref) else {
            throw DockExtensionError.gitFailed(
                operation: "ls-remote",
                detail: ref.map { "no branch, tag, or ref named \"\($0)\"" } ?? "remote has no HEAD"
            )
        }
        return sha
    }

    /// Creates (or replaces) a detached checkout of `sha` at `directory`.
    ///
    /// Tries a depth-1 fetch of the exact SHA first (GitHub supports
    /// unadvertised-object fetches; the `uploadpack.*` overrides make local
    /// `file://` fixtures behave the same), falling back to a full fetch for
    /// servers that refuse SHA fetches.
    public func materializeCheckout(cloneURL: String, sha: String, into directory: URL) async throws {
        let fileManager = FileManager.default
        do {
            // A swallowed removal failure would resurface downstream as a
            // misleading "remote origin already exists" git error; report the
            // real staging problem instead.
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DockExtensionError.stagingFailed(detail: error.localizedDescription)
        }

        _ = try await runGit(["init", "--quiet", directory.path], operation: "init")
        _ = try await runGit(
            ["-C", directory.path, "remote", "add", "origin", cloneURL],
            operation: "remote add"
        )
        do {
            _ = try await runGit(
                [
                    "-C", directory.path,
                    "-c", "uploadpack.allowAnySHA1InWant=true",
                    "-c", "uploadpack.allowReachableSHA1InWant=true",
                    "fetch", "--quiet", "--depth", "1", "origin", sha,
                ],
                operation: "fetch",
                timeout: .seconds(600)
            )
        } catch {
            // Server refused the SHA fetch; fall back to a full fetch.
            _ = try await runGit(
                ["-C", directory.path, "fetch", "--quiet", "origin"],
                operation: "fetch",
                timeout: .seconds(600)
            )
        }
        _ = try await runGit(
            ["-C", directory.path, "checkout", "--quiet", "--detach", sha],
            operation: "checkout"
        )
    }

    /// Whether `ref` looks like a full 40-hex commit SHA.
    public static func isFullSha(_ ref: String) -> Bool {
        ref.count == 40 && ref.lowercased().unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    /// Picks the best `ls-remote` line for `ref`: branch, then peeled tag,
    /// then tag, then exact refname, then first line.
    static func pickRevision(from output: String, ref: String?) -> String? {
        let entries: [(sha: String, refName: String)] = output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard let sha = parts.first, Self.isFullSha(String(sha)) else { return nil }
                let refName = parts.count > 1 ? String(parts[1]) : ""
                return (String(sha).lowercased(), refName)
            }
        guard !entries.isEmpty else { return nil }
        guard let ref else {
            return entries.first { $0.refName == "HEAD" }?.sha ?? entries.first?.sha
        }
        let preferredOrder = [
            "refs/heads/\(ref)",
            "refs/tags/\(ref)^{}",
            "refs/tags/\(ref)",
            ref,
        ]
        for preferred in preferredOrder {
            if let match = entries.first(where: { $0.refName == preferred }) {
                return match.sha
            }
        }
        return entries.first?.sha
    }

    private func runGit(
        _ arguments: [String],
        operation: String,
        timeout: Duration = .seconds(120)
    ) async throws -> DockExtensionProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result: DockExtensionProcessResult
        do {
            result = try await runner.run(
                executableURL: gitExecutableURL,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        } catch {
            throw DockExtensionError.gitUnavailable(detail: error.localizedDescription)
        }
        if result.timedOut {
            throw DockExtensionError.gitFailed(operation: operation, detail: "timed out")
        }
        guard result.exitStatus == 0 else {
            let detail = Self.tail(result.standardError.isEmpty ? result.standardOutput : result.standardError)
            if detail.localizedCaseInsensitiveContains("xcode-select")
                || detail.localizedCaseInsensitiveContains("developer tools") {
                throw DockExtensionError.gitUnavailable(detail: detail)
            }
            throw DockExtensionError.gitFailed(operation: operation, detail: detail)
        }
        return result
    }

    private static func tail(_ text: String, limit: Int = 500) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + trimmed.suffix(limit)
    }
}
