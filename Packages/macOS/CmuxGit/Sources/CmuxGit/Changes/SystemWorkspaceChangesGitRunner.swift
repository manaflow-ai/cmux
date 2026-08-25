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
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
    ]

    private let executableURL: URL
    private let environment: [String: String]
    private let boundedCommandWallTimeLimit: TimeInterval

    init(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        boundedCommandWallTimeLimit: TimeInterval = 30
    ) {
        self.executableURL = executableURL
            ?? SystemGitExecutableResolver(environment: environment).executableURLs().first
            ?? URL(fileURLWithPath: "/usr/bin/git")
        var scopedEnvironment = environment
        for key in Self.repositorySelectionEnvironmentKeys {
            scopedEnvironment.removeValue(forKey: key)
        }
        let commandScopedKeys = scopedEnvironment.keys.filter {
            $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_")
        }
        for key in commandScopedKeys {
            scopedEnvironment.removeValue(forKey: key)
        }
        // Preserve the caller's explicit system-config opt-out; it does not
        // redirect repository selection and is part of Git's normal semantics.
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
