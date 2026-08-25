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
    ]

    private let executableURLs: [URL]
    private let environment: [String: String]
    private let boundedCommandWallTimeLimit: TimeInterval
    private let allowsExecutableFallback: Bool

    init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        boundedCommandWallTimeLimit: TimeInterval = 30,
        allowsExecutableFallback: Bool = false
    ) {
        self.init(
            executableURLs: executableURL.map { [$0] }
                ?? SystemGitExecutableResolver(environment: environment).executableURLs(),
            environment: environment,
            boundedCommandWallTimeLimit: boundedCommandWallTimeLimit,
            allowsExecutableFallback: allowsExecutableFallback
        )
    }

    /// Creates a runner with an ordered executable list. The next candidate is
    /// tried when an earlier Git exits non-zero, which lets an older system Git
    /// yield to a package-manager Git that understands reftable.
    init(
        executableURLs: [URL],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        boundedCommandWallTimeLimit: TimeInterval = 30,
        allowsExecutableFallback: Bool = false
    ) {
        self.executableURLs = executableURLs.isEmpty
            ? SystemGitExecutableResolver(environment: environment).executableURLs()
            : executableURLs
        var scopedEnvironment = environment
        for key in Self.repositorySelectionEnvironmentKeys {
            scopedEnvironment.removeValue(forKey: key)
        }
        scopedEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        self.environment = scopedEnvironment
        self.boundedCommandWallTimeLimit = max(0, boundedCommandWallTimeLimit)
        self.allowsExecutableFallback = allowsExecutableFallback
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
        let limit = Int64(max(0, maximumOutputByteCount))
        var output = Data()
        output.reserveCapacity(min(max(0, maximumOutputByteCount), Self.readChunkByteCount))
        let result = try execute(
            arguments: arguments,
            directory: directory,
            maximumOutputByteCount: limit,
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
        prepareAttempt: () throws -> Void,
        consume: (Data) throws -> Void
    ) throws -> (exitCode: Int32, wasTruncated: Bool) {
        let deadline = DispatchTime.now() + boundedCommandWallTimeLimit
        var lastResult: (exitCode: Int32, wasTruncated: Bool)?
        var lastError: Error?

        let candidates = allowsExecutableFallback
            ? executableURLs.prefix(4)
            : executableURLs.prefix(1)
        for executableURL in candidates {
            guard !WorkspaceChangesCancellationSignal.isCurrentCancelled else { break }
            let now = DispatchTime.now()
            guard now < deadline || lastResult == nil else { break }
            let remainingNanoseconds = deadline > now
                ? deadline.uptimeNanoseconds - now.uptimeNanoseconds
                : 0
            let remainingSeconds = Double(remainingNanoseconds) / 1_000_000_000

            do {
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
                let result = (
                    exitCode: exit.exitCode,
                    wasTruncated: readResult.wasTruncated
                        || WorkspaceChangesCancellationSignal.isCurrentCancelled
                        || exit.timedOut
                        || exit.wasSignaled
                )
                lastResult = result
                // A bounded read or cancellation is final. For a non-zero,
                // non-truncated Git exit, try the next executable candidate.
                if result.wasTruncated || result.exitCode == 0 {
                    return result
                }
            } catch {
                lastError = error
            }
        }

        if let lastResult { return lastResult }
        throw lastError ?? POSIXError(.ENOENT)
    }
}
