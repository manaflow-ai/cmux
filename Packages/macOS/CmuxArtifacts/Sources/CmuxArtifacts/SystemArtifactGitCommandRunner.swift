import Darwin
import Foundation

/// Process-backed Git command runner used by the local artifact repository.
struct SystemArtifactGitCommandRunner: ArtifactGitCommandRunning {
    private let executableURL: URL
    private let environment: [String: String]
    private let timeout: TimeInterval

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5
    ) {
        self.executableURL = executableURL
        self.environment = environment.filter { !$0.key.hasPrefix("GIT_") }
        self.timeout = max(0.01, timeout)
    }

    func terminationStatus(arguments: [String]) async throws -> Int32 {
        let process = makeProcess(arguments: arguments)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        return try await execute(process)
    }

    func run(
        arguments: [String],
        standardInput: Data?
    ) async throws -> (terminationStatus: Int32, standardOutput: Data) {
        let process = makeProcess(arguments: arguments)
        let outputFile = try makeUnlinkedFile()
        defer { try? outputFile.close() }
        process.standardOutput = outputFile
        let inputFile: FileHandle?
        if let standardInput {
            let file = try makeUnlinkedFile()
            do {
                try file.write(contentsOf: standardInput)
                try file.seek(toOffset: 0)
                process.standardInput = file
                inputFile = file
            } catch {
                try? file.close()
                throw error
            }
        } else {
            process.standardInput = FileHandle.nullDevice
            inputFile = nil
        }
        defer { try? inputFile?.close() }

        let terminationStatus = try await execute(process)
        try Task.checkCancellation()
        try outputFile.seek(toOffset: 0)
        let standardOutput = try outputFile.readToEnd() ?? Data()
        return (terminationStatus, standardOutput)
    }

    private func execute(_ process: Process) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await waitForTermination(process)
            }
            group.addTask {
                // This bounded deadline is the intended subprocess timeout.
                try await Task.sleep(for: .seconds(timeout))
                throw ArtifactGitCommandError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private func waitForTermination(_ process: Process) async throws -> Int32 {
        let cancellation = ArtifactGitProcessCancellation(process: process)
        let status = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                guard cancellation.beginLaunch() else {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                    cancellation.didLaunch()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return status
    }

    private func makeProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func makeUnlinkedFile() throws -> FileHandle {
        var template = Array("\(NSTemporaryDirectory())cmux-artifact-git.XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        unlink(template)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
