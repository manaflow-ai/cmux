import Darwin
import Foundation

/// Runs `/usr/bin/git` with optional locking disabled and repository scope isolated.
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

    private let executableURL: URL
    private let environment: [String: String]
    private let boundedCommandWallTimeLimit: TimeInterval

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        boundedCommandWallTimeLimit: TimeInterval = 30
    ) {
        self.executableURL = executableURL
        var scopedEnvironment = environment
        for key in Self.repositorySelectionEnvironmentKeys {
            scopedEnvironment.removeValue(forKey: key)
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
        let limit = Int64(max(0, maximumOutputByteCount))
        var output = Data()
        output.reserveCapacity(min(max(0, maximumOutputByteCount), Self.readChunkByteCount))
        let result = try execute(
            arguments: arguments,
            directory: directory,
            maximumOutputByteCount: limit
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
            maximumOutputByteCount: max(0, maximumOutputByteCount)
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
        consume: (Data) throws -> Void
    ) throws -> (exitCode: Int32, wasTruncated: Bool) {
        let process = try WorkspaceChangesGitProcess.spawn(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            directory: directory,
            wallTimeLimit: boundedCommandWallTimeLimit
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
