import Foundation

/// Resolves the working directory a restored agent session should run in.
///
/// This is the single source of truth shared by the app-side resolver
/// (``RestorableAgentSessionIndex`` in the app target) and the CLI surface-resume-binding publisher
/// (`publishAgentSurfaceResumeBinding` in the standalone `cmux-cli` target), so both apply one
/// policy: directory-namespaced agents use the transcript's project directory when available, then
/// pin the launch cwd; id-keyed agents keep the runtime cwd.
///
/// The type is a stateless value; construct one at the call site (`AgentResumeWorkingDirectory()`)
/// rather than reaching through a static namespace, per the package design discipline.
///
/// ```swift
/// // A Claude session launched in /repo that drifted into /repo/worktrees/x:
/// AgentResumeWorkingDirectory().resolve(
///     kind: "claude",
///     runtimeCwd: "/repo/worktrees/x",
///     launchWorkingDirectory: "/repo"
/// ) // == "/repo"  (so `claude --resume` finds the transcript filed under /repo)
/// ```
public struct AgentResumeWorkingDirectory: Sendable, Equatable {
    /// Creates a working-directory resolver. The type holds no state.
    public init() {}

    /// Classifies an agent by its raw kind id (e.g. `"claude"`, `"codex"`, `"hermes-agent"`).
    ///
    /// - Parameter kind: the agent's raw kind identifier (``RestorableAgentKind/rawValue`` in the app).
    /// - Returns: ``AgentCwdNamespacing/cwdInFile`` for id-keyed agents that record the cwd in the
    ///   session file; ``AgentCwdNamespacing/byDirectory`` for everything else (including unknown
    ///   kinds, which prefer the launch cwd).
    public func cwdNamespacing(forKind kind: String) -> AgentCwdNamespacing {
        switch kind {
        case "codex", "opencode", "amp", "antigravity", "rovodev", "hermes-agent":
            return .cwdInFile
        default:
            return .byDirectory
        }
    }

    /// The directory a resumed agent session should `cd` into.
    ///
    /// Claude's transcript path identifies the project directory that `claude --resume` searches, so
    /// it wins when one of the candidate directories encodes to that project name. If the hook's
    /// launch and runtime directories have both drifted, the transcript's first record can recover
    /// the original cwd after a round-trip slug check. Other directory-namespaced agents prefer the
    /// launch working directory; id-keyed agents keep the runtime cwd. Inputs are trimmed and empty
    /// values are treated as absent.
    ///
    /// - Parameters:
    ///   - kind: the agent's raw kind identifier.
    ///   - runtimeCwd: the agent's last-reported runtime cwd (may have drifted).
    ///   - launchWorkingDirectory: the directory the agent was launched in.
    ///   - transcriptPath: the hook-reported Claude transcript path, when available.
    /// - Returns: the directory to `cd` into, or `nil` when neither input is usable.
    public func resolve(
        kind: String,
        runtimeCwd: String?,
        launchWorkingDirectory: String?,
        transcriptPath: String? = nil
    ) -> String? {
        let runtime = normalized(runtimeCwd)
        let launch = normalized(launchWorkingDirectory)
        switch cwdNamespacing(forKind: kind) {
        case .cwdInFile:
            return runtime ?? launch
        case .byDirectory:
            if kind == "claude",
               let transcriptCwd = claudeTranscriptWorkingDirectory(
                   transcriptPath: transcriptPath,
                   candidates: [launch, runtime].compactMap { $0 }
               ) {
                return transcriptCwd
            }
            return launch ?? runtime
        }
    }

    private func claudeTranscriptWorkingDirectory(
        transcriptPath: String?,
        candidates: [String]
    ) -> String? {
        guard let transcriptPath = normalized(transcriptPath),
              let projectDirectory = transcriptProjectDirectoryName(at: transcriptPath) else {
            return nil
        }

        let slug = ClaudeProjectSlug()
        if let candidate = candidates.first(where: {
            slug.slug(forWorkingDirectory: $0) == projectDirectory
        }) {
            return candidate
        }

        // SessionStart may arrive after both cwd values have drifted. Claude records the launch
        // cwd in the first JSONL record; only accept it when it round-trips to the transcript's
        // project directory so a malformed or foreign transcript cannot redirect the resume.
        guard let recordedCwd = recordedWorkingDirectory(in: transcriptPath),
              slug.slug(forWorkingDirectory: recordedCwd) == projectDirectory else {
            return nil
        }
        return recordedCwd
    }

    private func transcriptProjectDirectoryName(at path: String) -> String? {
        let expandedPath = (path as NSString).expandingTildeInPath
        let components = expandedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        // Prefer the last `projects` component so a user's path can itself contain a directory
        // with that name. Claude's current direct and nested layouts both live below this segment.
        if let projectsIndex = components.lastIndex(of: "projects"),
           projectsIndex + 1 < components.count {
            return components[projectsIndex + 1]
        }

        // Keep a conservative fallback for custom config roots that do not contain a literal
        // `projects` component in the supplied path.
        var directory = (expandedPath as NSString).deletingLastPathComponent
        if (directory as NSString).lastPathComponent == "messages" {
            directory = (directory as NSString).deletingLastPathComponent
            directory = (directory as NSString).deletingLastPathComponent
        }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private func recordedWorkingDirectory(in path: String) -> String? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let handle = FileHandle(forReadingAtPath: expandedPath) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let cwd = normalized(object["cwd"] as? String) else {
                continue
            }
            return cwd
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
