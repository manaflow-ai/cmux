public import Foundation
import Darwin
import os

/// Diagnostics for partial pipe reads; mirrors the app-side ProcessPipeReader
/// warning the lifted code emitted (file-scoped `os.Logger` per house style).
private let logger = Logger(subsystem: "com.cmuxterm.app", category: "MultiWindowRouter")

/// Runs the bundled cmux CLI against the app's control socket to route a
/// request to a specific window, capturing its output.
///
/// This is the production ``MultiWindowRouting``, lifted faithfully from
/// AppDelegate's `runMultiWindowRouteCLI`: it spawns the CLI with an implicit
/// `--socket <path>` argument pair, an explicit child environment (the child
/// inherits nothing beyond what is injected), waits for exit, then reads both
/// streams to end-of-file. A launch failure is encoded as the legacy `"-1"`
/// status with the error description in `stderr`.
///
/// Isolation design: the router holds only immutable `Sendable` configuration
/// (CLI URL, socket path, environment), so there is no state to protect and an
/// actor would serialize unrelated route calls for no benefit (the same ruling
/// that made `CmuxProcess.CommandRunner` a stateless struct). The blocking
/// `waitUntilExit` contract is preserved in this faithful lift; callers invoke
/// it off the main thread exactly as the legacy call site did.
public struct MultiWindowRouter: MultiWindowRouting, Sendable {
    private let cliURL: URL
    private let socketPath: String
    // Environment is value-like once copied; stored immutable so the struct
    // stays Sendable.
    private let environment: [String: String]

    /// Creates a router for one CLI binary, socket, and child environment.
    /// - Parameters:
    ///   - cliURL: The bundled cmux CLI executable.
    ///   - socketPath: The control socket path passed to every call as
    ///     `--socket <path>`.
    ///   - environment: The complete child process environment (replaces, not
    ///     merges with, the app's environment).
    public init(cliURL: URL, socketPath: String, environment: [String: String]) {
        self.cliURL = cliURL
        self.socketPath = socketPath
        self.environment = environment
    }

    /// Runs the CLI with `arguments` and captures its outcome.
    ///
    /// Implements ``MultiWindowRouting/route(arguments:)``. Blocks the calling
    /// thread until the CLI exits; see the type docs for the isolation
    /// rationale.
    public func route(arguments: [String]) -> MultiWindowRouteResult {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--socket", socketPath] + arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return MultiWindowRouteResult(status: "-1", stdout: "", stderr: String(describing: error))
        }
        process.waitUntilExit()

        let stdoutData = readDataToEndOfFileOrEmpty(from: stdoutPipe.fileHandleForReading)
        let stderrData = readDataToEndOfFileOrEmpty(from: stderrPipe.fileHandleForReading)
        return MultiWindowRouteResult(
            status: String(process.terminationStatus),
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Reads `fileHandle` to end-of-file, retrying `EINTR`, returning partial
    /// data (with a logged warning) on a read error. Lifted from the app-side
    /// `ProcessPipeReader.readDataToEndOfFileOrEmpty`, which stays app-target
    /// (it is shared by other app sources).
    private func readDataToEndOfFileOrEmpty(from fileHandle: FileHandle) -> Data {
        let chunkSize = 64 * 1024
        let fileDescriptor = fileHandle.fileDescriptor
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, chunkSize)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
                continue
            }
            if bytesRead == 0 {
                return data
            }
            let code = errno
            if code == EINTR {
                continue
            }
            logger.warning(
                "multiWindowRouter.readFailed errno=\(Int(code), privacy: .public) fd=\(fileDescriptor, privacy: .public) partialBytes=\(data.count, privacy: .public)"
            )
            return data
        }
    }
}
