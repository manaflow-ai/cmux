import Foundation

/// A subprocess described by its executable path and arguments, run
/// synchronously to capture its standard output as a UTF-8 string.
///
/// Unlike ``CommandRunner`` (which drains `stdout`/`stderr` concurrently, honors a
/// timeout, and resolves bare command names against `PATH`), this blocks the
/// calling thread until the process exits and is deliberately minimal: it
/// requires an absolute executable path, discards standard error, and returns
/// only standard output. It exists for callers that already run on a background
/// queue and want a one-shot, allocation-bounded capture (each call runs inside
/// its own `autoreleasepool`).
///
/// ```swift
/// let output = SynchronousProcessOutputCapture(
///     executablePath: "/bin/ps",
///     arguments: ["-t", ttyList, "-o", "pid=,tty="]
/// ).captureStandardOutput()
/// ```
public struct SynchronousProcessOutputCapture: Sendable {
    /// The absolute path to the executable to run.
    public let executablePath: String
    /// The arguments passed to the executable.
    public let arguments: [String]

    /// Creates a synchronous capture for `executablePath` invoked with `arguments`.
    /// - Parameters:
    ///   - executablePath: An absolute path to the executable.
    ///   - arguments: The arguments passed to the executable.
    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }

    /// Runs the process and returns its standard output decoded as UTF-8.
    ///
    /// Blocks until the process exits. Returns `nil` when the process fails to
    /// launch or its output is not valid UTF-8. Standard input and standard error
    /// are routed to the null device.
    /// - Returns: The captured standard output, or `nil` on launch failure or
    ///   invalid UTF-8.
    public func captureStandardOutput() -> String? {
        autoreleasepool {
            let process = Process()
            let stdoutPipe = Pipe()
            let stdoutReadHandle = stdoutPipe.fileHandleForReading
            let stdoutWriteHandle = stdoutPipe.fileHandleForWriting

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            defer {
                try? stdoutReadHandle.close()
                try? stdoutWriteHandle.close()
            }

            do {
                try process.run()
            } catch {
                return nil
            }

            // Close the parent's write end before reading. This is required:
            // The pipe reader blocks until EOF, which only occurs when every
            // write-fd holder (parent + child) has closed its copy. Keeping the
            // parent's copy open would deadlock the read. The defer below is a
            // safety net for the error path (process.run() throws), not a
            // substitute for this explicit close.
            try? stdoutWriteHandle.close()
            let data = stdoutReadHandle.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                return nil
            }
            return output
        }
    }
}
