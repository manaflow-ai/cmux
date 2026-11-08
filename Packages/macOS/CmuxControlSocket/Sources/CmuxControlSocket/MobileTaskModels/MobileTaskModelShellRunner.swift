import Darwin
import Foundation

/// Runs a short command through the user's login shell with a hard deadline.
public struct MobileTaskModelShellRunner: Sendable {
    private let shellPath: String

    /// Creates a login-shell command runner.
    ///
    /// - Parameter shellPath: Absolute shell path, normally `$SHELL` or `/bin/zsh`.
    public init(shellPath: String) {
        self.shellPath = shellPath
    }

    /// Runs a command and captures UTF-8 standard output.
    ///
    /// The blocking `Process` and pipe work stays in a detached utility task.
    /// A cancellable clock task sends `SIGKILL` at the requested deadline.
    ///
    /// - Parameters:
    ///   - command: Static command text passed to the login shell with `-lc`.
    ///   - timeout: Hard execution deadline.
    /// - Returns: Standard output on a zero exit, otherwise `nil`.
    public func run(command: String, timeout: Duration) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = ["-lc", command]
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }

            let processID = process.processIdentifier
            let timeoutTask = Task.detached(priority: .utility) {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return false
                }
                _ = Darwin.kill(processID, SIGKILL)
                return true
            }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutTask.cancel()
            let timedOut = await timeoutTask.value
            guard !timedOut, process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }
}
