import Dispatch
import Foundation

/// Selects one Git executable that can read a repository's reference format.
nonisolated struct GitReferenceRunnerSelector: Sendable {
    private static let maximumProbeOutputByteCount = 16 * 1_024

    private let runners: [any WorkspaceChangesGitRunning]
    private let probesReferenceFormat: Bool
    private let wallTimeLimit: TimeInterval

    /// Creates a production selector from bounded PATH/system candidates.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        wallTimeLimit: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime
    ) {
        let resolver = SystemGitExecutableResolver(environment: environment)
        self.runners = resolver.referenceExecutableURLs().map { executableURL in
            SystemWorkspaceChangesGitRunner(
                executableURL: executableURL,
                environment: environment,
                boundedCommandWallTimeLimit: wallTimeLimit
            ) as any WorkspaceChangesGitRunning
        }
        self.probesReferenceFormat = true
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
        return nil
    }

    /// Returns the injected runner without requiring a repository probe.
    var firstRunner: (any WorkspaceChangesGitRunning)? { runners.first }
}
