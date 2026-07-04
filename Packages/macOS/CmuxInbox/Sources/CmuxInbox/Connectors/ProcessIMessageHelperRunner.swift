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
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8) ?? "cmux-imsg failed"
                throw InboxError.connectorUnavailable(message)
            }
            return data
        }.value
    }
}
