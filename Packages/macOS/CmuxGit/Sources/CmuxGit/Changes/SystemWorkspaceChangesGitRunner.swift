import Darwin
import Foundation

/// Runs bounded Git commands with repository scope isolated.
struct SystemWorkspaceChangesGitRunner: WorkspaceChangesGitRunning {
    private static let readChunkByteCount = 64 * 1024
    /// Ambient variables that can redirect Git away from the requested directory.
    private static let repositorySelectionEnvironmentKeys: Set<String> = [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CEILING_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_DIR",
        "GIT_INDEX_FILE",
        "GIT_NAMESPACE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_WORK_TREE",
        "GIT_REFERENCE_BACKEND",
        "GIT_CONFIG",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
    ]
    private static let isolationOnlyEnvironmentKeys: Set<String> = [
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_SYSTEM",
    ]

    private let executableURL: URL
    private let fallbackExecutableURLs: [URL]
    private let environment: [String: String]
    private let boundedCommandWallTimeLimit: TimeInterval

    init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        boundedCommandWallTimeLimit: TimeInterval = 30,
        isolateRepositoryConfig: Bool = false,
        fallbackExecutableURLs: [URL]? = nil
    ) {
        let candidates = if let executableURL {
            [executableURL] + (fallbackExecutableURLs ?? [])
        } else {
            SystemGitExecutableResolver(environment: environment).executableURLs()
        }
        self.executableURL = candidates.first ?? URL(fileURLWithPath: "/usr/bin/git")
        self.fallbackExecutableURLs = Array(candidates.dropFirst().prefix(3))
        var scopedEnvironment = environment
        // Never allow ambient repository-selection or command-injected config
        // variables to redirect a command away from its explicit directory.
        for key in Self.repositorySelectionEnvironmentKeys {
            scopedEnvironment.removeValue(forKey: key)
        }
        let commandScopedKeys = scopedEnvironment.keys.filter {
            $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_")
        }
        for key in commandScopedKeys {
            scopedEnvironment.removeValue(forKey: key)
        }
        if isolateRepositoryConfig {
            for key in Self.isolationOnlyEnvironmentKeys {
                scopedEnvironment.removeValue(forKey: key)
            }
            // Reference plumbing must observe only the requested repository's
            // local config. Global/system includes can inject unrelated remotes.
            scopedEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
            scopedEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        }
        scopedEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        self.environment = scopedEnvironment
        self.boundedCommandWallTimeLimit = max(0, boundedCommandWallTimeLimit)
    }

    func run(arguments: [String], in directory: URL) throws -> WorkspaceChangesGitResult {
        try run(
            arguments: arguments,
            in: directory,
            maximumOutputByteCount: Int.max
        )
    }

    func run(
        arguments: [String],
        in directory: URL,
        maximumOutputByteCount: Int
    ) throws -> WorkspaceChangesGitResult {
        try run(
            arguments: arguments,
            in: directory,
            maximumOutputByteCount: maximumOutputByteCount,
            wallTimeLimit: boundedCommandWallTimeLimit
        )
    }

    func run(
        arguments: [String],
        in directory: URL,
        maximumOutputByteCount: Int,
        wallTimeLimit: TimeInterval
    ) throws -> WorkspaceChangesGitResult {
        let limit = Int64(max(0, maximumOutputByteCount))
        var output = Data()
        output.reserveCapacity(min(max(0, maximumOutputByteCount), Self.readChunkByteCount))
        let result = try execute(
            arguments: arguments,
            directory: directory,
            maximumOutputByteCount: limit,
            wallTimeLimit: wallTimeLimit,
            prepareAttempt: {
                output.removeAll(keepingCapacity: true)
            }
        ) { chunk in
            output.append(chunk)
        }
        return WorkspaceChangesGitResult(
            output: output,
            exitCode: result.exitCode,
            standardOutputWasTruncated: result.wasTruncated
        )
    }

    func run(
        arguments: [String],
        in directory: URL,
        writingOutputTo destination: URL,
        maximumOutputByteCount: Int64
    ) throws -> WorkspaceChangesGitResult {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destinationHandle = try FileHandle(forWritingTo: destination)
        defer { try? destinationHandle.close() }
        let result = try execute(
            arguments: arguments,
            directory: directory,
            maximumOutputByteCount: max(0, maximumOutputByteCount),
            wallTimeLimit: boundedCommandWallTimeLimit,
            prepareAttempt: {
                try destinationHandle.seek(toOffset: 0)
                try destinationHandle.truncate(atOffset: 0)
            }
        ) { chunk in
            try destinationHandle.write(contentsOf: chunk)
        }
        return WorkspaceChangesGitResult(
            output: Data(),
            exitCode: result.exitCode,
            standardOutputWasTruncated: result.wasTruncated
        )
    }

    private func execute(
        arguments: [String],
        directory: URL,
        maximumOutputByteCount: Int64,
        wallTimeLimit: TimeInterval,
        prepareAttempt: () throws -> Void,
        consume: (Data) throws -> Void
    ) throws -> (exitCode: Int32, wasTruncated: Bool) {
        let deadline = DispatchTime.now() + max(0, wallTimeLimit)
        let candidates = [executableURL] + fallbackExecutableURLs
        var lastResult: (exitCode: Int32, wasTruncated: Bool)?
        var lastError: (any Error)?
        for candidate in candidates {
            let now = DispatchTime.now()
            guard deadline > now else { break }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                / 1_000_000_000
            var attemptProducedOutput = false
            do {
                let result = try executeOnce(
                    executableURL: candidate,
                    arguments: arguments,
                    directory: directory,
                    maximumOutputByteCount: maximumOutputByteCount,
                    wallTimeLimit: remaining,
                    prepareAttempt: prepareAttempt,
                    consume: { chunk in
                        if !chunk.isEmpty { attemptProducedOutput = true }
                        try consume(chunk)
                    }
                )
                lastResult = result
                // Retry only the unmistakable unsupported/fatal Git exit with
                // no output; partial output is authoritative for status callers
                // and must not be erased by a fallback candidate.
                if result.exitCode != 128 || result.wasTruncated || attemptProducedOutput {
                    return result
                }
            } catch {
                lastError = error
                // A consumer may already have persisted a partial result; do not
                // clear it and retry another Git executable.
                if attemptProducedOutput {
                    throw error
                }
                if error is POSIXError {
                    continue
                }
                throw error
            }
        }
        if let lastResult { return lastResult }
        throw lastError ?? POSIXError(.EIO)
    }

    private func executeOnce(
        executableURL: URL,
        arguments: [String],
        directory: URL,
        maximumOutputByteCount: Int64,
        wallTimeLimit: TimeInterval,
        prepareAttempt: () throws -> Void,
        consume: (Data) throws -> Void
    ) throws -> (exitCode: Int32, wasTruncated: Bool) {
        let deadline = DispatchTime.now() + max(0, wallTimeLimit)
        let now = DispatchTime.now()
        let remainingNanoseconds = deadline > now
            ? deadline.uptimeNanoseconds - now.uptimeNanoseconds
            : 0
        let remainingSeconds = Double(remainingNanoseconds) / 1_000_000_000

        try prepareAttempt()
        let process = try WorkspaceChangesGitProcess.spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            directory: directory,
            wallTimeLimit: remainingSeconds
        )
        let readResult: WorkspaceChangesGitProcess.ReadResult
        do {
            readResult = try process.readOutput(
                maximumByteCount: maximumOutputByteCount,
                chunkByteCount: Self.readChunkByteCount,
                consume: consume
            )
        } catch {
            process.terminateForBoundedRead()
            _ = process.finish()
            throw error
        }
        if readResult.wasTruncated || WorkspaceChangesCancellationSignal.isCurrentCancelled {
            process.terminateForBoundedRead()
        }
        let exit = process.finish()
        return (
            exitCode: exit.exitCode,
            wasTruncated: readResult.wasTruncated
                || WorkspaceChangesCancellationSignal.isCurrentCancelled
                || exit.timedOut
                || exit.wasSignaled
        )
    }
}
