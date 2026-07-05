public import Foundation

/// Process-based `cmux-imsg` runner.
public struct ProcessIMessageHelperRunner: IMessageHelperRunning {
    /// Creates a process runner.
    public init() {}

    /// Runs a helper command and returns stdout when the process exits zero.
    public func run(helperURL: URL, arguments: [String], stdin: Data?) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = helperURL
            process.arguments = arguments
            let output = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = output
            process.standardError = errorPipe
            if let stdin {
                let input = Pipe()
                process.standardInput = input
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: stdin)
                try input.fileHandleForWriting.close()
            } else {
                try process.run()
            }
            // Drain both pipes while the helper runs. Waiting for exit before
            // reading deadlocks once either stream exceeds the ~64 KB pipe
            // buffer: the child blocks in write while the parent blocks in
            // waitUntilExit().
            async let drainedOutput = Self.drain(output.fileHandleForReading)
            async let drainedError = Self.drain(errorPipe.fileHandleForReading)
            let data = await drainedOutput
            let errorData = await drainedError
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8) ?? "cmux-imsg failed"
                throw InboxError.connectorUnavailable(message)
            }
            return data
        }.value
    }

    /// Reads a pipe to end-of-file off the cooperative pool so both helper
    /// streams drain concurrently while the process is still running.
    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
