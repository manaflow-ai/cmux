public import Foundation

extension GitDiffService {
    /// Creates a git diff service.
    ///
    /// - Parameters:
    ///   - gitExecutableURL: Git executable URL.
    ///   - fileSystemStatExecutableURL: Filesystem metadata executable URL.
    ///   - environment: Base process environment.
    ///   - processDeadlineSeconds: Wall-clock bound on each git subprocess.
    ///     The mobile RPC timeout cancels only the awaiting task, never the
    ///     spawned process, so a stalled git (fsmonitor hang, dead network
    ///     filesystem) is terminated here instead of accumulating across
    ///     phone retries.
    ///   - operationDeadlineSeconds: Aggregate wall-clock bound shared by all
    ///     subprocesses in one logical query.
    ///   - processLifecycle: Injected admission and detached-reap service. App
    ///     callers share one instance across concurrent diff requests.
    public init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        fileSystemStatExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/stat"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processDeadlineSeconds: Double = 20,
        operationDeadlineSeconds: Double = 20,
        processLifecycle: GitProcessLifecycleService = GitProcessLifecycleService()
    ) {
        self.operationDeadlineSeconds = operationDeadlineSeconds
        self.processRunner = GitProcessRunner(
            gitExecutableURL: gitExecutableURL,
            fileSystemStatExecutableURL: fileSystemStatExecutableURL,
            environment: environment,
            processDeadlineSeconds: processDeadlineSeconds,
            processLifecycle: processLifecycle
        )
    }

    /// Resolves the enclosing repository root for a directory.
    ///
    /// - Parameter directory: Directory inside a git repository.
    /// - Returns: Repository root, or `nil` when `directory` is not in a repo.
    public func repositoryRoot(for directory: String) -> String? {
        guard case .success(let root) = repositoryRootResult(for: directory) else { return nil }
        return root
    }

    /// Resolves an enclosing repository root without flattening Git failures
    /// into the same result as a directory outside a repository.
    public func repositoryRootResult(for directory: String) -> GitDiffQueryResult<String> {
        withOperationDeadline {
            let result = runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])
            switch result.failure {
            case .timedOut:
                return .timedOut
            case .unsuccessfulExit:
                return .notFound
            case .cancelled, .launchFailed:
                return .failed
            case nil:
                guard let output = result.successOutput,
                      let root = removingGitLineTerminator(output),
                      !root.isEmpty else { return .notFound }
                return .success(root)
            }
        }
    }
}
