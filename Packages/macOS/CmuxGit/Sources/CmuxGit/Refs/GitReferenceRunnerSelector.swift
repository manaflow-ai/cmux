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
        guard let first = runners.first else { return nil }
        guard probesReferenceFormat else { return first }
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
        // ordinary symbolic-ref/rev-parse plumbing is usable. Validate those
        // candidates with a backend-neutral command before falling back to the
        // first path, so stale PATH entries cannot hide a later working Git.
        for runner in runners {
            let now = DispatchTime.now()
            guard deadline > now else { return nil }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                / 1_000_000_000
            guard let result = try? runner.run(
                arguments: ["symbolic-ref", "--quiet", "HEAD"],
                in: URL(fileURLWithPath: repository.workTreeRoot, isDirectory: true),
                maximumOutputByteCount: Self.maximumProbeOutputByteCount,
                wallTimeLimit: remaining
            ),
            !result.standardOutputWasTruncated,
            result.exitCode == 0 || result.exitCode == 1 else {
                continue
            }
            return runner
        }
        // `--show-ref-format` is newer than the standard plumbing commands.
        // Keep the first bounded runner as a compatibility fallback when the
        // optional capability probe is unsupported; its process runner can
        // still fall through to later executables on an actual backend error.
        guard deadline > DispatchTime.now() else { return nil }
        return first
    }

    /// Returns the injected runner without requiring a repository probe.
    var firstRunner: (any WorkspaceChangesGitRunning)? { runners.first }

    /// The bounded ordered candidates used by status fallback.
    var candidateRunners: [any WorkspaceChangesGitRunning] { runners }

    /// The aggregate wall-time budget for candidate status probes.
    var candidateWallTimeLimit: TimeInterval { wallTimeLimit }
}
