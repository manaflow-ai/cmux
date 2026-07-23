import Foundation

/// Runs `/usr/bin/git` with optional locking disabled.
struct SystemWorkspaceChangesGitRunner: WorkspaceChangesGitRunning {
    private static let readChunkByteCount = 64 * 1024

    private let executableURL: URL
    private let environment: [String: String]
    private let boundedCommandWallTimeLimit: TimeInterval

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        boundedCommandWallTimeLimit: TimeInterval = 30
    ) {
        self.executableURL = executableURL
        var nonLockingEnvironment = environment
        nonLockingEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        self.environment = nonLockingEnvironment
        self.boundedCommandWallTimeLimit = max(0, boundedCommandWallTimeLimit)
    }

    func run(arguments: [String], in directory: URL) throws -> WorkspaceChangesGitResult {
        let process = configuredProcess(arguments: arguments, directory: directory)
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return WorkspaceChangesGitResult(output: output, exitCode: process.terminationStatus)
    }

    func run(
        arguments: [String],
        in directory: URL,
        maximumOutputByteCount: Int
    ) throws -> WorkspaceChangesGitResult {
        let process = configuredProcess(arguments: arguments, directory: directory)
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let outputHandle = outputPipe.fileHandleForReading
        let deadlineTimer = deadlineTimer(for: process)
        defer { deadlineTimer.cancel() }
        let limit = max(0, maximumOutputByteCount)
        var output = Data()
        output.reserveCapacity(min(limit, Self.readChunkByteCount))
        var wasTruncated = limit == 0
        while output.count < limit {
            if Task.isCancelled {
                wasTruncated = true
                break
            }
            let remaining = limit - output.count
            let chunk = try outputHandle.read(
                upToCount: min(Self.readChunkByteCount, remaining)
            ) ?? Data()
            guard !chunk.isEmpty else { break }
            output.append(chunk)
            if Task.isCancelled {
                wasTruncated = true
                break
            }
            if output.count == limit {
                wasTruncated = true
                break
            }
        }
        if wasTruncated, process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        try? outputHandle.close()
        wasTruncated = wasTruncated || process.terminationReason == .uncaughtSignal
        return WorkspaceChangesGitResult(
            output: output,
            exitCode: process.terminationStatus,
            standardOutputWasTruncated: wasTruncated
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

        let process = configuredProcess(arguments: arguments, directory: directory)
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let outputHandle = outputPipe.fileHandleForReading
        let deadlineTimer = deadlineTimer(for: process)
        defer { deadlineTimer.cancel() }
        let limit = max(0, maximumOutputByteCount)
        var writtenByteCount: Int64 = 0
        var wasTruncated = false
        while true {
            if Task.isCancelled {
                wasTruncated = true
                break
            }
            let chunk = try outputHandle.read(upToCount: Self.readChunkByteCount) ?? Data()
            guard !chunk.isEmpty else { break }
            if Task.isCancelled {
                wasTruncated = true
                break
            }
            let remaining = limit - writtenByteCount
            guard remaining > 0 else {
                wasTruncated = true
                break
            }
            let acceptedCount = min(chunk.count, Int(min(remaining, Int64(Int.max))))
            try destinationHandle.write(contentsOf: chunk.prefix(acceptedCount))
            writtenByteCount += Int64(acceptedCount)
            if acceptedCount < chunk.count {
                wasTruncated = true
                break
            }
        }
        if wasTruncated, process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        try? outputHandle.close()
        wasTruncated = wasTruncated || process.terminationReason == .uncaughtSignal
        return WorkspaceChangesGitResult(
            output: Data(),
            exitCode: process.terminationStatus,
            standardOutputWasTruncated: wasTruncated
        )
    }

    private func configuredProcess(arguments: [String], directory: URL) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        return process
    }

    private func deadlineTimer(for process: Process) -> any DispatchSourceTimer {
        // A one-shot source is required because a synchronous pipe read needs an out-of-band deadline.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + boundedCommandWallTimeLimit)
        timer.setEventHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        timer.resume()
        return timer
    }
}
