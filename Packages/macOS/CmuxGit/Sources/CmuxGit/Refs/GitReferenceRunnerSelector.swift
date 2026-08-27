import Dispatch
import Foundation

/// Selects one Git executable that can read a repository's reference format.
nonisolated struct GitReferenceRunnerSelector: Sendable {
    private static let maximumProbeOutputByteCount = 16 * 1_024

    private let runners: [any WorkspaceChangesGitRunning]
    private let probesReferenceFormat: Bool
    private let wallTimeLimit: TimeInterval

    /// Creates a production selector from bounded PATH/system candidates.
    /// Set `probesReferenceFormat` to `false` for commands such as `status`
    /// that must work with older Git versions and do not need backend probing.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        wallTimeLimit: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime,
        isolateRepositoryConfig: Bool = true,
        probesReferenceFormat: Bool = true
    ) {
        let resolver = SystemGitExecutableResolver(environment: environment)
        let executableURLs = resolver.referenceExecutableURLs()
        self.runners = executableURLs.enumerated().map { index, executableURL in
            SystemWorkspaceChangesGitRunner(
                executableURL: executableURL,
                environment: environment,
                boundedCommandWallTimeLimit: wallTimeLimit,
                isolateRepositoryConfig: isolateRepositoryConfig,
                fallbackExecutableURLs: Array(executableURLs.dropFirst(index + 1))
            ) as any WorkspaceChangesGitRunning
        }
        self.probesReferenceFormat = probesReferenceFormat
        self.wallTimeLimit = max(0, wallTimeLimit)
    }

    /// Creates a selector around an injected runner without probing it.
    init(runner: any WorkspaceChangesGitRunning) {
        self.runners = [runner]
        self.probesReferenceFormat = false
        self.wallTimeLimit = GitMetadataSafetyConfiguration().gitStatusWallTime
    }

    /// Creates a selector with ordered injected runners for behavior tests.
    init(
        runners: [any WorkspaceChangesGitRunning],
        wallTimeLimit: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime
    ) {
        self.runners = runners
        self.probesReferenceFormat = true
        self.wallTimeLimit = max(0, wallTimeLimit)
    }

    /// Selects a runner using one shared capability-probe deadline.
    func select(
        repository: ResolvedGitRepository,
        deadline: DispatchTime? = nil
    ) -> (any WorkspaceChangesGitRunning)? {
        guard !runners.isEmpty else { return nil }
        guard probesReferenceFormat else { return runners[0] }
        let deadline = deadline ?? (DispatchTime.now() + wallTimeLimit)
        for runner in runners {
            let now = DispatchTime.now()
            guard deadline > now else { return nil }
            let remainingNanoseconds = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            let remainingSeconds = Double(remainingNanoseconds) / 1_000_000_000
            guard let result = try? runner.run(
                arguments: ["rev-parse", "--show-ref-format"],
                in: URL(fileURLWithPath: repository.workTreeRoot, isDirectory: true),
                maximumOutputByteCount: Self.maximumProbeOutputByteCount,
                wallTimeLimit: remainingSeconds
            ),
            result.exitCode == 0,
            !result.standardOutputWasTruncated,
            let output = String(data: result.output, encoding: .utf8),
            let format = GitMetadataService.normalizedBranchName(output),
            format == "files" || format == "reftable" else {
                continue
            }
            return runner
        }
        // Older Git versions may reject `--show-ref-format` even though their
        // ordinary plumbing is usable. Validate each candidate with a command
        // that must succeed for any repository, so a broken PATH entry cannot
        // hide a later working Git. `symbolic-ref` is not suitable here because
        // it exits 1 for a legitimate detached HEAD.
        for runner in runners {
            let now = DispatchTime.now()
            guard deadline > now else { return nil }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                / 1_000_000_000
            guard let result = try? runner.run(
                arguments: ["rev-parse", "--git-dir"],
                in: URL(fileURLWithPath: repository.workTreeRoot, isDirectory: true),
                maximumOutputByteCount: Self.maximumProbeOutputByteCount,
                wallTimeLimit: remaining
            ),
            !result.standardOutputWasTruncated,
            result.exitCode == 0,
            let output = String(data: result.output, encoding: .utf8),
            !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return runner
        }
        // No candidate proved that it can address the requested repository.
        // Returning nil keeps the caller's unreadable state conservative.
        return nil
    }

    /// Returns the injected runner without requiring a repository probe.
    var firstRunner: (any WorkspaceChangesGitRunning)? { runners.first }

    /// The bounded ordered candidates used by status fallback.
    var candidateRunners: [any WorkspaceChangesGitRunning] { runners }

    /// The aggregate wall-time budget for candidate status probes.
    var candidateWallTimeLimit: TimeInterval { wallTimeLimit }
}
